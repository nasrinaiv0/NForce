import { formatPhpCents, type PersonalPayrollDetail } from './accountingReview';
import { renderUnicodePayslip } from './payslipUnicodePdf';

/** Local-only, text-based PDF. No network, external links, embedded script or storage.
 * Unicode glyphs are embedded locally. Unsupported scripts fail closed.
 * Internal employee and workspace identifiers are included; no government identifiers.
 */
export function buildPayslipPdf(d:PersonalPayrollDetail,demo=false):string {
 const s=d.summary;
 const money=(v:string)=>formatPhpCents(v);
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
 return renderUnicodePayslip(lines);
}
