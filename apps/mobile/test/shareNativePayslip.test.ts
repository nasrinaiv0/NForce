import { beforeEach,describe,expect,it,vi } from 'vitest';
const m=vi.hoisted(()=>({available:vi.fn(),share:vi.fn(),write:vi.fn(),remove:vi.fn(),create:vi.fn()}));
vi.mock('expo-file-system',()=>({
 Paths:{cache:'private-cache'},
 Directory:class {exists=false; constructor(..._parts:unknown[]){} create(){this.exists=true;m.create();}delete(){this.exists=false;m.remove();}},
 File:class {uri='file:///private-cache/nforce-payslips/sample.pdf';constructor(..._parts:unknown[]){}create(){}write(s:string){m.write(s);}}
}));
vi.mock('expo-crypto',()=>({randomUUID:()=> 'fictional-random'}));
vi.mock('expo-sharing',()=>({isAvailableAsync:m.available,shareAsync:m.share}));
import { shareNativePayslip } from '@/lib/shareNativePayslip';
const pdf='%PDF-1.4\n%%EOF',name='nforce-payslip-2026-02-01-r1.pdf';
describe('native private PDF handoff',()=>{
 beforeEach(()=>{vi.clearAllMocks();m.available.mockResolvedValue(true);m.share.mockResolvedValue(undefined);});
 it('does not write when scope is invalid',async()=>{await expect(shareNativePayslip(pdf,name,()=>false)).rejects.toThrow();expect(m.write).not.toHaveBeenCalled();});
 it('cleans private file directory after successful share',async()=>{await shareNativePayslip(pdf,name,()=>true);expect(m.write).toHaveBeenCalledWith(pdf);expect(m.share).toHaveBeenCalledTimes(1);expect(m.remove).toHaveBeenCalledTimes(1);});
 it('cleans after share failure and blocks revoked scope',async()=>{m.share.mockRejectedValueOnce(new Error('cancelled'));await expect(shareNativePayslip(pdf,name,()=>true)).rejects.toThrow();expect(m.remove).toHaveBeenCalledTimes(1);let calls=0;await expect(shareNativePayslip(pdf,name,()=>++calls<3)).rejects.toThrow();expect(m.share).toHaveBeenCalledTimes(1);expect(m.remove).toHaveBeenCalledTimes(2);});
});
