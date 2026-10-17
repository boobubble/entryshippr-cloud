import { describe,it,expect,vi,beforeEach } from 'vitest';
const mocks=vi.hoisted(()=>({getUser:vi.fn(),rpc:vi.fn()}));
vi.mock('@supabase/supabase-js',()=>({createClient:()=>({auth:{getUser:mocks.getUser},rpc:mocks.rpc})}));
vi.mock('@tanstack/react-start/server',()=>({setResponseHeader:vi.fn()}));
import { authenticatedClient } from '@/lib/external-auth.server';
describe('Server admin authorization',()=>{
 beforeEach(()=>{vi.clearAllMocks();});
 it('rejects expired or invalid identity',async()=>{mocks.getUser.mockResolvedValue({data:{user:null},error:{message:'expired'}});await expect(authenticatedClient('x'.repeat(30),true)).rejects.toThrow('sign in');expect(mocks.rpc).not.toHaveBeenCalled();});
 it('rejects authenticated non-admin',async()=>{mocks.getUser.mockResolvedValue({data:{user:{id:'seller'}},error:null});mocks.rpc.mockResolvedValue({data:false,error:null});await expect(authenticatedClient('x'.repeat(30),true)).rejects.toThrow('Admins only');expect(mocks.rpc).toHaveBeenCalledWith('is_admin');});
 it('fails closed when role lookup fails',async()=>{mocks.getUser.mockResolvedValue({data:{user:{id:'seller'}},error:null});mocks.rpc.mockResolvedValue({data:true,error:{message:'unavailable'}});await expect(authenticatedClient('x'.repeat(30),true)).rejects.toThrow('Admins only');});
 it('allows verified admin only after database role result',async()=>{mocks.getUser.mockResolvedValue({data:{user:{id:'admin'}},error:null});mocks.rpc.mockResolvedValue({data:true,error:null});expect((await authenticatedClient('x'.repeat(30),true)).user.id).toBe('admin');});
});
