import { Directory, File, Paths } from 'expo-file-system';
import { randomUUID } from 'expo-crypto';
import * as Sharing from 'expo-sharing';

/** Use only the app-private cache; Android grants access via the OS share sheet.
 * Never use public Documents, a remote URL, a data URI, or external storage.
 * OS/recipient copies are outside our control. Clean our cache after return,
 * and on the next export after a prior process interruption.
 */
let sharing=false;
export async function shareNativePayslip(pdf:string,filename:string,authorized:()=>boolean) {
 if(sharing||!authorized()||!/^%PDF-1\.4\n/.test(pdf)||!/^(sample-)?nforce-payslip-\d{4}-\d{2}-\d{2}-r[12]\.pdf$/.test(filename))throw new Error('Share unavailable');
 sharing=true;
 let temporary:Directory|undefined;
 try{
  if(!await Sharing.isAvailableAsync()||!authorized())throw new Error('Share unavailable');
  const root=new Directory(Paths.cache,'nforce-private-payslips');
  if(root.exists)root.delete();
  root.create({intermediates:true});
  temporary=new Directory(root,randomUUID());temporary.create();
  const file=new File(temporary,filename);file.create();file.write(pdf);
  if(!authorized())throw new Error('Share unavailable');
  await Sharing.shareAsync(file.uri,{mimeType:'application/pdf',UTI:'com.adobe.pdf',dialogTitle:'Share confidential payslip'});
 }finally{
  try{if(temporary?.exists===true)temporary.delete();}finally{sharing=false;}
 }
}
