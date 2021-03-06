function [D1,D2,C2] = GetPOpt_wo_Interp_wRegenB(indE1,indE2,L)
%GetPOpt_wo_Interp_wRegenB Returns the optimal controls in the given state.
%                          Accounts for R.B.
%   Input: state, assumed ON GRID
%   Output: optimal control

global fullPolicyMtx; global P2; global P3; global MIN_LOAD; global epsilon3; global epsilon4;
global qValsMtx;

global RES_D2; global RES_C2;

%RES_D2=1; RES_C2=1;

pOpt=find(fullPolicyMtx(indE1,indE2,L-MIN_LOAD+1,:)==1); %(Find equal to 1)

%Get associated optimal controls
C2_Ind=remainder(pOpt,P3);
pOpt_int=(pOpt-C2_Ind)/P3+1;
D2_Ind=remainder(pOpt_int,P2);
D1_Ind=(pOpt_int-D2_Ind)/P2+1;
D1=D1_Ind-1; D2=(D2_Ind-1)/RES_D2; C2=(C2_Ind-1)/RES_C2;

end

