import { fontBase64, fontByteLength, glyphMap } from './payslipFont';

// ASCII transport keeps offsets identical for web Blob and native File.write.
// Visible text uses an embedded Unicode CID font with an explicit ToUnicode map.
const hex4=(n:number)=>n.toString(16).padStart(4,'0').toUpperCase();
const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
let embeddedFont:string|undefined;
function fontHex():string{
 if(embeddedFont!==undefined)return embeddedFont;
 const chunks:string[]=[];
 for(let i=0;i<fontBase64.length;i+=4){
  const a=alphabet.indexOf(fontBase64.charAt(i)),b=alphabet.indexOf(fontBase64.charAt(i+1));
  const c=alphabet.indexOf(fontBase64.charAt(i+2)),d=alphabet.indexOf(fontBase64.charAt(i+3));
  const v=(a<<18)|(b<<12)|(Math.max(c,0)<<6)|Math.max(d,0);
  chunks.push(((v>>16)&255).toString(16).padStart(2,'0'));
  if(c>=0)chunks.push(((v>>8)&255).toString(16).padStart(2,'0'));
  if(d>=0)chunks.push((v&255).toString(16).padStart(2,'0'));
 }
 const hex=chunks.join('');
 if(hex.length!==fontByteLength*2)throw new Error('Invalid embedded payslip font');
 embeddedFont=hex+'>';
 return embeddedFont;
}
function normalized(value:string):string[]{
 return Array.from(value.normalize('NFC')).map(ch=>{
  const cp=ch.codePointAt(0);
  if(cp===undefined||glyphMap[cp]===undefined)throw new Error('Unsupported payslip PDF glyph');
  return ch;
 });
}
function wrap(value:string):string[]{
 const result:string[]=[];let line='',width=0;
 for(const ch of normalized(value)){
  const advance=glyphMap[ch.codePointAt(0)!]![1];
  if(width+advance>55000&&line!==''){result.push(line);line='';width=0;}
  line+=ch;width+=advance;
 }
 result.push(line);return result;
}
const stream=(content:string,extra='')=>'<< /Length '+content.length+' '+extra+' >>\nstream\n'+content+'\nendstream';

export function renderUnicodePayslip(lines:readonly string[]):string{
 const groups:string[][]=[[]];
 for(const line of lines){if(/^Item \d+ \| /.test(line))groups.push([]);groups[groups.length-1]!.push(line);}
 const pages:string[][]=[[]];
 for(const group of groups){
  const wrapped=group.flatMap(wrap);
  let page=pages[pages.length-1]!;
  if(page.length>0&&page.length+wrapped.length>52){page=[];pages.push(page);}
  for(const line of wrapped){if(page.length>=52){page=[];pages.push(page);}page.push(line);}
 }
 const codes:number[]=[];const cids=new Map<number,number>();
 const encode=(s:string)=>{
  let out='';
  for(const ch of normalized(s)){
   const cp=ch.codePointAt(0)!;let cid=cids.get(cp);
   if(cid===undefined){codes.push(cp);cid=codes.length;cids.set(cp,cid);}
   out+=hex4(cid);
  }
  return '<'+out+'>';
 };
 const contents=pages.map((page,i)=>'BT /F1 9 Tf 42 796 Td 14 TL\n'+page.map(line=>encode(line)+' Tj T*').join('\n')+'\nET\nBT /F1 8 Tf 42 35 Td '+encode('Confidential | Page '+(i+1)+' of '+pages.length)+' Tj ET');
 const gidMap='0000'+codes.map(cp=>hex4(glyphMap[cp]![0])).join('')+'>';
 const widths=codes.map(cp=>glyphMap[cp]![1]).join(' ');
 const bf=codes.map((cp,i)=>'<'+hex4(i+1)+'> <'+hex4(cp)+'>');
 const mappings:string[]=[];
 for(let i=0;i<bf.length;i+=100){const chunk=bf.slice(i,i+100);mappings.push(chunk.length+' beginbfchar\n'+chunk.join('\n')+'\nendbfchar');}
 const unicode='/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /NForcePayslipUnicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n'+mappings.join('\n')+'\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend';
 const objects:string[]=[
  '<< /Type /Catalog /Pages 2 0 R >>','',
  '<< /Type /Font /Subtype /Type0 /BaseFont /NotoSansMono-Regular /Encoding /Identity-H /DescendantFonts [4 0 R] /ToUnicode 7 0 R >>',
  '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /NotoSansMono-Regular /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 5 0 R /DW 600 /W [1 ['+widths+']] /CIDToGIDMap 8 0 R >>',
  '<< /Type /FontDescriptor /FontName /NotoSansMono-Regular /Flags 33 /FontBBox [-616 -389 1800 1229] /ItalicAngle 0 /Ascent 1069 /Descent -293 /CapHeight 714 /StemV 80 /FontFile2 6 0 R >>',
  stream(fontHex(),'/Filter /ASCIIHexDecode /Length1 '+fontByteLength),
  stream(unicode),stream(gidMap,'/Filter /ASCIIHexDecode')
 ];
 const kids:string[]=[];
 for(const content of contents){
  const id=objects.length+1;kids.push(id+' 0 R');
  objects.push('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents '+(id+1)+' 0 R >>',stream(content));
 }
 objects[1]='<< /Type /Pages /Count '+pages.length+' /Kids ['+kids.join(' ')+'] >>';
 let out='%PDF-1.4\n';const offsets:number[]=[0];
 objects.forEach((obj,i)=>{offsets.push(out.length);out+=(i+1)+' 0 obj\n'+obj+'\nendobj\n';});
 const xref=out.length;
 return out+'xref\n0 '+offsets.length+'\n0000000000 65535 f \n'+offsets.slice(1).map(n=>String(n).padStart(10,'0')+' 00000 n \n').join('')+'trailer\n<< /Size '+offsets.length+' /Root 1 0 R >>\nstartxref\n'+xref+'\n%%EOF\n';
}
