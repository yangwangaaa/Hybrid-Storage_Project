%LP solution of IHDP (Value Iteration) for Hybrid Storage optimization
%warning('off', 'Octave:possible-matlab-short-circuit-operator');
clearvars -except X V;

global E_MIN; global E_MAX;
E_MIN=[0;0]; %Minimum energy to be stored (lower bound)
E_MAX=[5;4]; %Maximum energy to be stored (upper bound)

%Solver tolerance
tolerance=1e-6;

%% Input: initial state, horizon
%Initial stored energy (user-defined)
%Must be between MIN_STATE and MAX_STATE
E1_INIT=E_MAX(1); 
E2_INIT=E_MAX(2);

%% Model setup
global MAX_CHARGE; global MAX_DISCHARGE;
MAX_CHARGE=[0;100]; %Maximum charging of the supercapacitor
MAX_DISCHARGE=[5;4]; %Maximum discharging of the 1) battery and 2) supercap

global MIN_LOAD;
MIN_LOAD=0; %Minimum load expected
MAX_LOAD=MAX_DISCHARGE(1)+MAX_DISCHARGE(2);

MAX_NUM_ZEROS=3; %Maximum number of zero load counts before end sim

global ALPHA_C; global ALPHA_D; global BETA; global K;
ALPHA_C=[0.99;0.99]; %Efficiency of charging
ALPHA_D=[0.9;0.95]; %Efficiency of discharging
BETA=[0.99;0.99];    %Storage efficiency
K=2;           %Weighting factor for D1^2 cost
PERFECT_EFF=0;

%Discounted infinite horizon problem
global DISCOUNT; %Discount factor
DISCOUNT=0.99;

%% Definitions
global N2;

M=MAX_LOAD-MIN_LOAD+1;
N1=(E_MAX(1)-E_MIN(1)+1);
N2=(E_MAX(2)-E_MIN(2)+1);
P1=MAX_DISCHARGE(1)+1;
P2=MAX_DISCHARGE(2)+1;


epsilon=0.01; %Next state off grid rounding tolerance
epsilon2=0.0001; %Off grid state comparison tolerance

%% Initialization
E_Ind_Vect_p=[];      %Vector of current state energies
nextE_Ind_Vect_p=[];  %Vector of next state energies
aug_nextE_Ind_Vect_p=[]; %Augmented vector containing current state energies and next energies for currently infeasible states
aug_Vect_Ls_p=[]; %Same, but also including associated load values in each state

offGrdNxtE1E2_p=[]; %Array mapping single index to linear next state index, for states OFF THE GRID
numL_OffGrd_p=[]; %Vector of number of admissible loads in next states that are OFF THE GRID

numL_OffGrd=0; %Count number of admissible load values for a given NEXT energy state


global E_Ind_MtxALL; %Matrix of all states (element 0 if infeasible combo)
global CostMtx; %Matrix with 3 columns: a) E-state, b) load, c) associated cost. Used for approximation
CostMtx=[];

P_mtx={};   %Array of P matrices
P=[];       %Current P matrix
PF={};      %Array of P*F matrices

F_p=[]; G_p=[]; %F and G matrices, for mapping states

Lmin_p=[]; %Vector of minimum loads required at high discharge (for given p)
Lmin_offs_p=[]; %Vector of minimum load offsets for each E-state, to create CORRECT MAPPING in G matrix
E_Ind_Mtx_p=[]; %Matrix of E_Ind_MtxALL values, but for EACH value of p
P_fullmtx=[];   %Matrix of all probabilities

indL_Feas=[]; %Vector of feasible demands for ONE GIVEN combination of x and u
c_state=[];     %Vector of state-relevance weightings

p_max=0;    %Maximum number of controls to consider

%Flags for rounding next state to grid
boolRounded1=0; boolRounded2=0;

%% PART A: SET UP MATRICES
%For each possible control...
  for D1=0:MAX_DISCHARGE(1)
    for D2=0:MAX_DISCHARGE(2)
        %Map control to control index
        D1_Ind=D1+1; D2_Ind=D2+1;
        %Get combination #(p)
        p=D2_Ind+P2*(D1_Ind-1);
        
        indCount=0; %Index for feasible state #, for a given value of p
        
        %For each state at an iteration...
        for E_Ind1=1:(E_MAX(1)-E_MIN(1)+1)
            for E_Ind2=1:(E_MAX(2)-E_MIN(2)+1)
                %Map state index to state
                E1=E_MIN(1)+(E_Ind1-1);
                E2=E_MIN(2)+(E_Ind2-1);
                
                %Get index of current state energies in vector of state energies
                E_Ind=(E_Ind1-1)*N2+E_Ind2;
                
                if(D1>E1 || D2>E2)  %If discharge too high for state...
                    %IGNORE
                else
                    %Index row in E-state indices mtx (for feasible E-state) same as VALUE of E-state index
                    rowInd_Emtx = E_Ind;
                    %Determine MINIMUM required load for high discharge, to
                    %not overflow E2 (one for each E-state)
                    minL=max(  ceil(1/ALPHA_C(2)*(BETA(2)*E2-E_MAX(2)-D2/ALPHA_D(2))+D1+D2),  0); %Calculate Lmin
                    Lmin_p=[Lmin_p; minL]; %Create vector
                    
                    %For each perturbation at the CURRENT time...
                    for indL=1:(D1+D2-MIN_LOAD+1)
                        %Map index to value of load
                        L=indL+MIN_LOAD-1;

                        %STEP 0
                        %Calculate the state these values of u and w will lead to, even if
                        %impossible...
                        [nextE1,nextE2]=optNextStateLimited(E1,E2,D1,D2,L);

                        %If next state is amongst those achievable with a given perturbance....
                        if(nextE1<=E_MAX(1) && nextE1>=E_MIN(1))
                            if(nextE2<=E_MAX(2) && nextE2>=E_MIN(2))
                                %IF meeting following conditions: (C_MIN and C_MAX)
                                %1) net supply (discharging) never below demand, 2) not charging cap. too quickly
                                if(~((D1+D2-L)<0||(D1+D2-L)>MAX_CHARGE(2)))
                                  %Count the number of feasible states for a given set of controls (D1,D2)
                                  indCount=indCount+1; %... and use as an index
                                  
                                  %STEP 1: create vector and matrix of FEASIBLE state energies for each load
                                  %Add state energy index to vector for current value of p (D1,D2 combo)
                                  E_Ind_Vect_p=[E_Ind_Vect_p;E_Ind];
                                  %Add state energy index to matrix of ALL FEASIBLE energies
                                  %DO NOT RESET at end. Will overwrite with same values (and add) each time, which is ok.
                                  E_Ind_MtxALL(rowInd_Emtx,indL)=E_Ind;
                                  E_Ind_Mtx_p(rowInd_Emtx,indL)=E_Ind;
                                    
                                  %Map state to state index, to find cost of next state based on its index
                                  if(abs((nextE1-E_MIN(1)+1)-round(nextE1-E_MIN(1)+1))<epsilon)
                                      nextE_Ind1=round(nextE1-E_MIN(1)+1);  %IF within error bound, round
                                      boolRounded1=1;
                                  else
                                      nextE_Ind1=nextE1-E_MIN(1)+1;         %.. Otherwise, will interpolate
                                  end
                                  if(abs((nextE2-E_MIN(2)+1)-round(nextE2-E_MIN(2)+1))<epsilon)
                                      nextE_Ind2=round(nextE2-E_MIN(2)+1);
                                      boolRounded2=1;
                                  else
                                      nextE_Ind2=nextE2-E_MIN(2)+1;
                                  end

                                  %STEP 2: create vector of next state energies for each load
                                  %Get index of next state energy in vector of state energies
                                  if boolRounded1==1
                                      nextE_Ind=(nextE_Ind1-1)*N2+nextE_Ind2;
                                  else
                                      %PUT SOMETHING ELSE?????
                                      nextE_Ind=(nextE_Ind1-1)*N2+nextE_Ind2;
                                  end
                                  %Add next state energy index to vector of FEASIBLE next state energies
                                  nextE_Ind_Vect_p=[nextE_Ind_Vect_p;nextE_Ind];
                                  
                                  %STEP A: create array of next state indices that are off-grid
                                  %Mapping from 2 indices to linear index
                                  if round(nextE_Ind)~=nextE_Ind %If NOT INTEGER...... i.e. EITHER component of next state is off grid...
                                      offGrdNxtE1E2_p=[offGrdNxtE1E2_p;nextE_Ind1,nextE_Ind2,nextE_Ind];
                                  end
                                   
                                  %STEP 3: determine feasible loads
                                  %Add indL to list of FEASIBLE loads for this combination of u and x
                                  indL_Feas=[indL_Feas;indL];
                                  %Create vector of minimum load values for each E-state, WITH repeats (to add OFFSETS in G matrix)
                                  Lmin_offs_p=[Lmin_offs_p;minL];
                                else
                                  %If no feasible state for this combination of (E1,E2) and L...
                                  nextE_Ind=-1; %Flag next state as impossible
                                end
                            else
                                %If no feasible state for this combination of (E1,E2) and L...
                                nextE_Ind=-1; %Flag next state as impossible
                            end
                        else
                            %If no feasible state for this combination of (E1,E2) and L...
                            nextE_Ind=-1; %Flag next state as impossible
                        end
                        
                        %STEP 4
                        %Create p-th vector g, for constraint
                        if(nextE_Ind~=-1) %If this state leads to a feasible next state...
                            gVec_p(indCount)=CtrlCost(D1,D2,L); %Cost of stage is given by CtrlCost
                        else %Else if infeasible next state...
                            %DO NOTHING
                        end
                    end

                    %Reset list of feasible loads (next state)
                    indL_Feas=[];
                end
            end
        end      
    
        %Count number of feasible loads for NEXT E-states off grid (NOT CURRENT ONES)
      %Steps B-D
      %Count for ALL possible controls in NEXT STATE...
      for i=1:size(offGrdNxtE1E2_p,1) %For each next state...
          %Maximum load previously achieved by all ctrls (starting point, to not double-count)
          maxL_prev=0; %Reset maximum previous load value
          
          for D1_next=0:MAX_DISCHARGE(1)
            for D2_next=0:MAX_DISCHARGE(2)
                nextE1=offGrdNxtE1E2_p(i,1)+E_MIN(1)-1; nextE2=offGrdNxtE1E2_p(i,2)+E_MIN(2)-1;
                
                %Get number of FEASIBLE next loads
                %Check excess discharge condition
                if(~(D1_next>nextE1 || D2_next>nextE2))
                    %For each perturbation at the NEXT time...
                    for indL=(maxL_prev+1):(D1_next+D2_next-MIN_LOAD+1) %TRY ONLY PERTURBATIONS ABOVE PREVIOUS MAX
                        L=indL+MIN_LOAD-1;
                        [next_nextE1,next_nextE2]=optNextStateLimited(nextE1,nextE2,D1_next,D2_next,L);
                        %Check other conditions
                        if(next_nextE1<=E_MAX(1) && next_nextE1>=E_MIN(1))
                            if(next_nextE2<=E_MAX(2) && next_nextE2>=E_MIN(2))
                                if(~((D1_next+D2_next-L)<0||(D1_next+D2_next-L)>MAX_CHARGE(2)))
                                    %If feasible, increment number
                                        numL_OffGrd=numL_OffGrd+1;
                                        maxL_prev=maxL_prev+1;
                                        %If feasible load with one set of discharges, no need to test others
                                        %D1_next=MAX_DISCHARGE(1)+1; D2_next=MAX_DISCHARGE(2)+1;
                                end
                            end
                        end
                    end
                end
                
            end
          end
          
         %Store # for this next state
         numL_OffGrd_p(i)=numL_OffGrd;
         %Reset feasible loads count, for subsequent NEXT energy state
         numL_OffGrd=0;
      end    
        
    %If at least one feasible state, consider this control
    if (~isempty(gVec_p))
        %Store vector data in cell array
        g{p}=gVec_p';
        E_Ind_Vect{p}=E_Ind_Vect_p;
        nextE_Ind_Vect{p}=nextE_Ind_Vect_p;
        Lmin{p}=Lmin_p;
        Lmin_offs{p}=Lmin_offs_p;
        E_Ind_Mtx{p}=E_Ind_Mtx_p;
        offGrdNxtE1E2{p}=offGrdNxtE1E2_p;
        numLoads_OffGrd{p}=numL_OffGrd_p;
        
        %Continue testing next control
        p_max=p_max+1;
    else
        %Else, IGNORE
        %Also, STOP TESTING MORE CONTROLS (max feasible reached)
        D1=MAX_DISCHARGE(1);
        D2=MAX_DISCHARGE(2);
    end
    
    %Reset matrices/vectors
    nextE_Ind_Vect_p=[];
    E_Ind_Vect_p=[];
    gVec_p=[];
    Lmin_p=[];
    Lmin_offs_p=[];
    E_Ind_Mtx_p=[];
    offGrdNxtE1E2_p=[];
    numL_OffGrd_p=[];
    
    end
  end
  
  
  
  
  %STEP 5: Construct vector of ALL FEASIBLE energies, for all control
  E_Ind_VectALL=[];
  E_Ind_VectALL_andLs=[]; %Array with associated loads
  for row=1:size(E_Ind_MtxALL,1)
      nnzRow=nnz(E_Ind_MtxALL(row,:));
      E_Ind_Mtx_nzRow=E_Ind_MtxALL(row,1:nnzRow);
      E_Ind_VectALL=[E_Ind_VectALL; E_Ind_Mtx_nzRow'];
      E_Ind_VectALL_andLs=[E_Ind_VectALL_andLs; E_Ind_Mtx_nzRow', (0:nnzRow-1)'];
  end
  
  %STEP 6: Create full probability matrix
  %SET DISTRIBUTION: UNIFORM
  %(Note: can't create until E_Ind_MtxALL complete, so outside main loop)
  for r=1:size(E_Ind_MtxALL,1)
      P_fullmtx(r,:)=E_Ind_MtxALL(r,:)/sum(E_Ind_MtxALL(r,:)); %<----------------For UNIFORM probability, just NORMALIZE rows of feasible states!!
  end
  
  for p=1:p_max
    E_Ind_Vect_p=E_Ind_Vect{p};
    nextE_Ind_Vect_p=nextE_Ind_Vect{p};
    Lmin_offs_p=Lmin_offs{p};
    numLoads_OffGrd_p=numLoads_OffGrd{p};
    
    %STEP 7: Create augmented vector containing current E-states - EXCLUDING those nextly infeasible - AND ALSO next E-states
    %(Note: doing after E_Ind_VectALL complete)
    augVectRow=1; %Index row in new augmented vector
    r=1; offGrdNxtE_Idx=1; %Start from beginning
    while r<(length(nextE_Ind_Vect_p)+1) %For each next E-state WITH CURRENT CONTROL COMBO (p)
        if (r~=1) %...IN MOST CASES
            %If next E-state already counted once, do not double-count...
            while r<(length(nextE_Ind_Vect_p)+1) && nnz(abs(nextE_Ind_Vect_p(1:r-1)-nextE_Ind_Vect_p(r))<epsilon2) %(If at least one prev element matches current)
                if round(nextE_Ind_Vect_p(r))~=nextE_Ind_Vect_p(r) %If off grid, also skip to subsequent unrepeated number of loads (associated)
                    offGrdNxtE_Idx=offGrdNxtE_Idx+1;
                end
                r=r+1; %Skip to next unrepeated E-state
            end
        end
        if(r~=(length(nextE_Ind_Vect_p)+1))
            %Determine TOTAL number of possible loads for that E-state, given ANY POSSIBLE control used
            
            %If off grid, do step E
            if round(nextE_Ind_Vect_p(r))~=nextE_Ind_Vect_p(r)
                numRepNextE=numLoads_OffGrd_p(offGrdNxtE_Idx);
                offGrdNxtE_Idx=offGrdNxtE_Idx+1;
            else %Otherwise...        
                numRepNextE=nnz(E_Ind_VectALL==nextE_Ind_Vect_p(r)); %Number of possible loads is number of times repeated in E_Ind_VectALL
            end
            
            %Add given E-state to augmented vector that many times (for each load)
            aug_nextE_Ind_Vect_p(augVectRow:(augVectRow+numRepNextE-1),1)=nextE_Ind_Vect_p(r);
            aug_Vect_Ls_p(augVectRow:(augVectRow+numRepNextE-1))=(0:(numRepNextE-1))';
            augVectRow=augVectRow+numRepNextE; %Start adding at end next time 
        end
        r=r+1; %Manually increment index in while loop
    end
    
    %Also, exclude from the augmented vector states that are nextly infeasible
    nextlyInfE=~ismember(aug_nextE_Ind_Vect_p,nextE_Ind_Vect_p);
    aug_nextE_Ind_Vect_p(nextlyInfE)=[];
    Lmin_offs_p(nextlyInfE)=[];
    
    %Store in cell array
    aug_nextE_Ind_Vect{p}=aug_nextE_Ind_Vect_p;
    aug_Vect_Ls{p}=aug_Vect_Ls_p;
    
    %Get index of subsequent next state that is off the grid
    x=1;
    
    %STEP 8: Create each P matrix
    %For P matrix, select rows corresponding to components in nextE_Ind_Vect
    %(Note: doing after P_fullmtx completed)
    for r=1:length(E_Ind_Vect_p)
        Ind_nextE=nextE_Ind_Vect_p(r);    %Get index of state stored in r-th row of nextE_Ind_Vect (i.e. the next energy state)
        
        %Get column number of next row of probabilities as RELATED to the NEXT ENERGY STATE INDEX (mapping to deterministic component!!!)
        c=find(abs(aug_nextE_Ind_Vect_p-Ind_nextE)<epsilon2,1); %Get from position of FIRST Ind_nextE in AUG_nextE_Ind_Vect!!!!! (b/c same width as AUGMENTED VECTOR)
        
        %IF off grid, follow step F instead
        if round(Ind_nextE)~=Ind_nextE
            %Count number of non-zero load probabilities for next state Ind_nextE
            nnzProb_nextE=numLoads_OffGrd_p(x);
            %Get non-zero probabilities
            prob_nextE=1/nnzProb_nextE*ones(1,nnzProb_nextE)';
            x=x+1;
        else %Otherwise...
            %Count number of non-zero probabilities in associated E-state row of P_fullmtx (i.e. Ind_nextE)
            nnzProb_nextE=nnz(P_fullmtx(Ind_nextE,:));      %Should be equal to number of repeats in nextE_Ind_Vect
            %Get said non-zero probabilities
            prob_nextE=nonzeros(P_fullmtx(Ind_nextE,:));
        end
        
        %Store subscript pairs and associated values in array P
        len=length(prob_nextE); 
        cols=c:(c+nnzProb_nextE-1);
        P=[P;r*ones(len,1),cols',prob_nextE];

        %Fill in row r with said probabilities
        %P(r,c:(c+nnzProb_nextE-1))=prob_nextE';
    end
        
    %Store in p-th PF matrix, as well as in own P_mtx
    PF{p}=sparse(P(:,1),P(:,2),P(:,3)); %Store as SPARSE MATRIX 
    P_mtx{p}=P;
    %Reset matrices/vectors
    P=[];
    aug_nextE_Ind_Vect_p=[];
    aug_Vect_Ls_p=[];
  end
  
  
  
  
  %STEP 9: Construct each F matrix
  for p=1:p_max
      aug_nextE_Ind_Vect_p=aug_nextE_Ind_Vect{p};
      aug_Vect_Ls_p=aug_Vect_Ls{p};
      offGrdNxtE1E2_p=offGrdNxtE1E2{p};
      %Index COLUMN of F matrix by ROW number of E_Ind_VectALL
      row=1; %Row being checked in E_Ind_VectALL to start when starting on next E_Ind vector. Reset it
      
      %Go through next E-state index vector for current value of p...
      for r=1:length(aug_nextE_Ind_Vect_p)
          
          %IF next state is off grid...
          if round(aug_nextE_Ind_Vect_p(r))~=aug_nextE_Ind_Vect_p(r)
              
              %Step G:
              
              %Get individual off-grid next state indices
              idx=find(abs(offGrdNxtE1E2_p(:,3)-aug_nextE_Ind_Vect_p(r))<epsilon2);
              idx=idx(1); %Take only first element if repeats in offGrdNxtE1E2_p ................. ASSUMING REPEATED OFF-GRID linear INDICES MAP TO SAME SET OF index pairs
              
              nextE1_Ind=offGrdNxtE1E2_p(idx,1);
              nextE2_Ind=offGrdNxtE1E2_p(idx,2);
              nextL=aug_Vect_Ls_p(r);
              
              for col=1:length(E_Ind_VectALL)
                  %Get individual current state indices
                  E2_Ind=remainder(E_Ind_VectALL(col),N2);
                  E1_Ind=(E_Ind_VectALL(col)-E2_Ind)/N2+1;
                  L=E_Ind_VectALL_andLs(col,2);
                  
                  %INTERPOLATION
                  %Check if (nextE1,nextE2) is on edge of square
                  %If so, apply different interpolation
                  if nextL==L
                      if nextE1_Ind==E1_Ind
                          if floor(nextE2_Ind)==E2_Ind
                              q=1-(nextE2_Ind-E2_Ind);
                          elseif ceil(nextE2_Ind)==E2_Ind
                              q=1-(E2_Ind-nextE2_Ind);
                          else 
                              q=0;
                          end
                      elseif nextE2_Ind==E2_Ind
                          if floor(nextE1_Ind)==E1_Ind
                              q=1-(nextE1_Ind-E1_Ind);
                          elseif ceil(nextE1_Ind)==E1_Ind
                              q=1-(E1_Ind-nextE1_Ind);
                          else 
                              q=0;
                          end
                      %If on neither edge...
                      else 
                          %Check to find 4  points closest to (nextE1,nextE2) off grid.... FIND (E1_Ind, E2_Ind)
                          %CASE 1: round E1 down, round E2 down
                          if floor(nextE1_Ind)==E1_Ind && floor(nextE2_Ind)==E2_Ind
                              q=(1-(nextE1_Ind-E1_Ind))*(1-(nextE2_Ind-E2_Ind));
                          %CASE 2: round E1 up, round E2 down
                          elseif ceil(nextE1_Ind)==E1_Ind && floor(nextE2_Ind)==E2_Ind
                              q=(1-(E1_Ind-nextE1_Ind))*(1-(nextE2_Ind-E2_Ind));
                          %CASE 3: round E1 down, round E2 up
                          elseif floor(nextE1_Ind)==E1_Ind && ceil(nextE2_Ind)==E2_Ind
                              q=(1-(nextE1_Ind-E1_Ind))*(1-(E2_Ind-nextE2_Ind));
                          %CASE 4: round E1 up, round E2 up
                          elseif ceil(nextE1_Ind)==E1_Ind && ceil(nextE2_Ind)==E2_Ind
                              q=(1-(E1_Ind-nextE1_Ind))*(1-(E2_Ind-nextE2_Ind));
                          else
                             q=0; %If this state on grid not used for interpolation (not corner of encompassing square)
                          end
                      end
                  else
                      q=0;
                  end
                      
                  
                  %Store subscript pairs and associated weightings in F_p
                  if q~=0
                    F_p=[F_p;r,col,q]; %Use states on grid for interpolation, with WEIGHTING q
                  end
              end
              
          else %Otherwise, if ON-GRID...
              
              %If next state is currently infeasible...
              if aug_nextE_Ind_Vect_p(r)<E_Ind_VectALL(row) %(i.e. NOT continuously increasing in augmented vector)
                 row=1; %Restart from beginning of E_Ind_VectALL to find the state <----- ASSUMING ONLY 1 distinct new currently infeasible state!
              end

              while(E_Ind_VectALL(row)~=aug_nextE_Ind_Vect_p(r)) %While not reached mapping column in F (ONLY 1 per row)...
                  row=row+1;    %Continue
              end

              %Store subscript pairs and associated 1's (feasible next) in array F_p 
              F_p=[F_p;r,row,1]; %Mark next state as feasible
              row=min(row+1,length(E_Ind_VectALL)); %Start at next column in F next time, saturating at maximum
              %^-------- Assuming continuously increasing in augmented vector (fixed above)
          end
      end
      
      if isempty(F_p)   %If empty, ignore
         F{p}=0;
      else      %IN MOST CASES... 
        F{p}=sparse(F_p(:,1),F_p(:,2),F_p(:,3),max(F_p(:,1)),length(E_Ind_VectALL)); %STORE AS SPARSE MATRIX
        %Also add extra zeros at end to ensure dimensions of F{p} and E_Ind_VectALL match
      end
     
      %Correct for infeasible neighbouring states for next state interpolation in F matrix
      for i=1:size(F{p},1)
          if sum(F{p}(i,:))~=1
              %Distribute missing weight evenly to remaining neighbouring states
              inds=find(F{p}(i,:));%Indices of remaining states
              F{p}(i,inds)=F{p}(i,inds)+(1-sum(F{p}(i,:)))/nnz(F{p}(i,:));
          end
      end
      
      F_p=[]; %Reset
      debug_p=[];
      
      if isempty(PF{p}) %If no next state..
          PF{p}=0;  %Ignore constraint
      else      %IN MOST CASES...
         PF{p} = PF{p}*F{p}; %Finish PF matrices 
      end
  end
  
  %STEP 10: Construct each G matrix
  for p=1:p_max
      E_Ind_Vect_p=E_Ind_Vect{p};
      Lmin_offs_p=Lmin_offs{p};
      %Index COLUMN of G matrix by ROW number of E_Ind_VectALL
      row=1; %Reset row being checked in E_Ind_VectALL to start when start on next E_Ind vector
      
      %Go through E-state index vector for current value of p...
      for r=1:length(E_Ind_Vect_p)
          %Find distinct new E-state
          if(r==1)
              boolNewEState=1;
          else
              if(E_Ind_Vect_p(r)~=E_Ind_Vect_p(r-1))
                 boolNewEState=1;
              else
                  boolNewEState=0;
              end
          end
          while(E_Ind_VectALL(row)~=E_Ind_Vect_p(r)) %While not reached mapping column in G (ONLY 1 per row)...
              row=row+1;    %Continue
          end
          if(boolNewEState==1)  %Only if distinct new state...
              row=row+Lmin_offs_p(r); %Add minimum load offset to first state #
          else
              %Otherwise, do nothing because already starting from offset
          end
          
          %Store subscript pairs and associated 1's (feasible next) in array G_p 
          G_p=[G_p;r,row,1]; %Mark current state as feasible
          row=min(row+1,length(E_Ind_VectALL));  %Start at next column in G next time (continuously increasing)
      end
      
      if isempty(G_p)   %If empty, ignore constraint
         G{p}=0;
      else      %IN MOST CASES... 
         G{p}=sparse(G_p(:,1),G_p(:,2),G_p(:,3),max(G_p(:,1)),length(E_Ind_VectALL)); %STORE AS SPARSE MATRIX
        %Also add extra zeros at end to ensure dimensions of G{p} and E_Ind_VectALL match
      end

      G_p=[]; %Reset
  end
  
  %If get empty g vector...
  for p=1:p_max
    if isempty(g{p})
        disp('ERROR!!'); %Error!!!
       g{p}=zeros(length(E_Ind_VectALL),1); %Set equal to zeros
    end
  end
  
  %% CORRECTED MATRICES (REMAINING infeasible states removed)
  %1) Coefficients
  Q=[];
  for p=1:p_max
    %Create full 'A' matrices for coefficients (A=G-alpha*PF)
    A{p}=G{p}-DISCOUNT*PF{p};
    %Adjoin A matrices to form Q
    Q=[Q;A{p}];
  end
  
  %If empty columns in Q...
  if (~all(any(Q,1)))
      disp('ERROR!!!!!'); %ERROR
     Q(:,~any(Q,1))=[]; %Remove, for now
  end
  
  %2) Constants
  %Create full 'b' vector for constants
  b=[];
  for p=1:p_max
    b=[b;g{p}];
  end
  
  %% PART B: OPTIMIZATION
  
  % Find state-relevance vector for minimization, c
  % TAKE c TO BE STEADY STATE ENTERING PROBABILITIES FOR EACH STATE
  % Probabilities are given in P_fullmtx (non-zero for feasible states)
  trP_fullmtx=P_fullmtx';
  c_state=trP_fullmtx(:); %Get probabilities for all states

  c_state(c_state==0)=[]; %Remove zero probability states
  
  %Created LP matrices and vectors.
  %Run optimization problem, and find primal as well as dual.
  cvx_begin
    grbControl.LPMETHOD = 1; % Use dual simplex method
    params.OptimalityTol = tolerance; %Set tolerance
    variable cost(size(Q,2))
    dual variables d
    %dual variables d2
    maximize( c_state'*cost )
    subject to
        d : Q*cost <= b
        %d2: cost >= 0 %Never active
  cvx_end
  %Set negative values to zero
  cost(cost<0)=0;
  %Get vector of optimal dual
  optD = d;
  
  
  %Format cost vector into E1xE2 matrices (one for each value of load)

    ConvCosts=FormatCostVect(cost);
    
    %% PART C: STATIONARY POLICY
    %PART 1: Create vector of probabilities of states (marginalized over control applied (denominator))
    %1) Augment optD vector to include probabilities of infeasible states too (0's)
    %Make each E_Ind_Mtx same size to compare ALL states between different
    %values of p, once in vector form
    %->Augmented vectors for given values of p (i.e. like augmented versions of
    %E_Ind_VectALL, and subsets of E_MtxALL_Vect)
    E_MtxALL_Vect_subs={};
    for p=1:p_max
        E_Ind_Mtx_p=E_Ind_Mtx{p};
        E_Ind_Mtx_p(:,size(E_Ind_Mtx_p,2)+1:size(E_Ind_MtxALL,2))=0; %Pad with zeros on sid to make same size
        %Convert to vector
        trE_Ind_Mtx_p=E_Ind_Mtx_p';
        E_MtxALL_Vect_subs{p}=trE_Ind_Mtx_p(:);
    end
    
    %2) Create augmented vectors of probabilities for ALL states - feasible
    %AND INFEASIBLE TOO - for EACH CONTROL p
    
    %For each element in E_MtxALL_Vect_subs{p}, if...
    %a) 0, append 0 to aug_optD_subP{p}
    %b) non-zero, append some value from optD to aug_optD_subP{p}
    %where some value is next value in for i=1:p-1 sumLen=sumLen+len(vecti) end optD(sumLen:sumLen+len(vectp))
    aug_optD_subP={};
    indOptD=1;
    for p=1:p_max
        aug_optD_subP_p=[];
        E_MtxALL_Vect_subs_p=E_MtxALL_Vect_subs{p};
       for i=1:length(E_MtxALL_Vect_subs_p)
           if(E_MtxALL_Vect_subs_p(i)==0)
              aug_optD_subP_p=[aug_optD_subP_p;0];
           else
               %Find value in subvector of optD just by continuously
               %indexing through optD in order <--------------------------Assuming optD linearly indexed in order (E2, E1, L, D2, D1)
               aug_optD_subP_p=[aug_optD_subP_p;optD(indOptD)];
               indOptD=indOptD+1;
           end
       end
       aug_optD_subP{p}=aug_optD_subP_p;
    end
    
    %3) Marginalise: sum vector components
    d_state=zeros(length(aug_optD_subP{1}),1); %Initialize
    for(p=1:p_max)
       d_state=d_state+aug_optD_subP{p}; %Sum over control values
    end
    
    %PART 2: Get stationary probabilities vector
    %Create augmented optD vector, for ALL states
    aug_optD=[];
    for p=1:p_max
        aug_optD=[aug_optD;aug_optD_subP{p}];
    end
    %Create vector with vector d_state duplicated p_max times and appended
    %(to allow for dividing each probability by marginalized value)
    dup_ones=ones(p_max,1);
    d_state_dup=kron(dup_ones,d_state);
    %Divide to get stationary probabilities vector for ALL states (augmented)
    aug_pi=aug_optD./d_state_dup;
    
    %Create augmented vector of all E_MtxALL_Vect_subs vectors
    aug_E_MtxALL_Vect=[];
    for p=1:p_max
        aug_E_MtxALL_Vect=[aug_E_MtxALL_Vect;E_MtxALL_Vect_subs{p}];
    end
    %Get stationary probabilities vector for ONLY feasible states (non-zero
    %in aug_E_MtxALL_Vect)
    pi=aug_pi(aug_E_MtxALL_Vect~=0);