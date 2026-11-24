import { formatPhpCents, type PersonalPayrollDetail } from './accountingReview';

/** Local-only, text-based PDF. No network, external links, embedded script or storage.
 * Non-ASCII characters are represented as Unicode code points, not silently dropped.
 * Internal employee and workspace identifiers are included; no government identifiers.
 */
export function buildPayslipPdf(d:PersonalPayrollDetail,demo=false):string {
 const s=d.summary;
 const money=(v:string)=>formatPhpCents(v).replace('₱','PHP ');
 const lines=[demo?'NFORCE | FICTIONAL SAMPLE':'NFORCE | CONFIDENTIAL PERSONAL PAYSLIP',
 'Released accrual - NOT proof of payment', 'Period: '+s.periodStart+' to '+s.periodEnd+' | Revision '+s.revision,
 'Frequency: '+d.frequency,'Employee: '+s.userId,'Workspace: '+s.organizationId,
 'Released: '+(d.releasedAt??'Not recorded'),'Actual payment: Not confirmed','',
 'EARNINGS AND DEDUCTIONS','Gross pay: '+money(s.grossCents),
 'Basic salary: '+(d.basicCents===null?'Not recorded':money(d.basicCents)),
 'Premium pay: '+(d.premiumCents===null?'Not recorded':money(d.premiumCents)),
 'Taxable earnings before deductions: '+money((BigInt(s.grossCents)-BigInt(d.exemptCents)).toString()),
 'Non-taxable earnings: '+money(d.exemptCents),'Taxable income: '+money(d.taxableCents),
 'SSS employee: '+money(s.sssEmployeeCents),
 ...(d.sssRegularCents!==null&&d.sssRegularCents!==undefined&&d.sssMpfCents!==null&&d.sssMpfCents!==undefined?['  SSS regular: '+money(d.sssRegularCents),'  SSS provident: '+money(d.sssMpfCents)]:[]),
 'PhilHealth employee: '+money(s.philhealthEmployeeCents),'Pag-IBIG employee: '+money(s.pagibigEmployeeCents),
 'Employee contributions: '+money(s.employeeContributionCents),'Withholding: '+money(s.withholdingCents),
 'Total deductions: '+money((BigInt(s.employeeContributionCents)+BigInt(s.withholdingCents)).toString()),
 'NET PAY: '+money(s.netCents),'','WORK AND EARNINGS EVIDENCE',
 'Recorded instants retain source offsets; not necessarily clock punches.',
 'Line figures before period rounding; do not sum as additional earnings.'];
 d.items.forEach((i,index)=>lines.push('', 'Item '+(index+1)+' | '+i.code+' | '+(i.date??'Not recorded'),
  'Site: '+(i.siteReference??'Not recorded'),'Start: '+(i.start??'Not recorded')+' | End: '+(i.end??'Not recorded'),
  'Seconds: '+(i.seconds??'Not recorded')+' | Rate PHP/h: '+(i.hourlyRate??'Not recorded')+' | Factor: '+(i.multiplier??'Not recorded'),
  'Method: '+i.method,'Recorded PHP: '+(i.recordedAmount??'Not recorded')+' | Calculated PHP: '+(i.calculatedAmount??'Not recorded')));
 const ascii=(v:string)=>Array.from(v).map(c=>{const n=c.codePointAt(0)??0;return n>=32&&n<=126?c:n===10||n===13||n===9?' ':'[U+'+n.toString(16).toUpperCase()+']';}).join('');
 const escape=(v:string)=>v.replace(/[\\()]/g,c=>'\\'+c);
 // Keep a complete evidence record together where it fits; no one-line spill.
 // 52 lines at 14pt fit within the A4 content area above the footer.
 const groups:string[][]=[[]];
 for(const line of lines){
  if(/^Item \d+ \| /.test(line))groups.push([]);
  groups[groups.length-1]!.push(line);
 }
 const pages:string[][]=[[]];
 for(const group of groups){
  const wrapped=group.flatMap(x=>ascii(x).match(/.{1,88}/g)??['']);
  let page=pages[pages.length-1]!;
  if(page.length>0&&page.length+wrapped.length>52){page=[];pages.push(page);}
  for(const line of wrapped){
   if(page.length>=52){page=[];pages.push(page);}
   page.push(line);
  }
 }
 const objects:string[]=['<< /Type /Catalog /Pages 2 0 R >>','', '<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>'];
 const kids:string[]=[];
 pages.forEach((page,i)=>{
  const id=objects.length+1;kids.push(id+' 0 R');
  const content='BT /F1 9 Tf 42 796 Td 14 TL\n'+page.map(x=>'('+escape(x)+') Tj T*').join('\n')+'\nET\nBT /F1 8 Tf 42 35 Td (Confidential | Page '+(i+1)+' of '+pages.length+') Tj ET\n';
  objects.push('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents '+(id+1)+' 0 R >>','<< /Length '+content.length+' >>\nstream\n'+content+'endstream');
 });
 objects[1]='<< /Type /Pages /Count '+pages.length+' /Kids ['+kids.join(' ')+'] >>';
 let out='%PDF-1.4\n';const offsets=[0];
 objects.forEach((o,i)=>{offsets.push(out.length);out+=(i+1)+' 0 obj\n'+o+'\nendobj\n';});
 const xref=out.length;return out+'xref\n0 '+offsets.length+'\n0000000000 65535 f \n'+offsets.slice(1).map(n=>String(n).padStart(10,'0')+' 00000 n \n').join('')+'trailer\n<< /Size '+offsets.length+' /Root 1 0 R >>\nstartxref\n'+xref+'\n%%EOF\n';
}
