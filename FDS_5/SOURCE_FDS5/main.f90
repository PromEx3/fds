PROGRAM FDS  
 
! Fire Dynamics Simulator, Main Program, Single CPU version

USE PRECISION_PARAMETERS
USE MESH_VARIABLES
USE GLOBAL_CONSTANTS
USE TRAN
USE DUMP
USE READ_INPUT
USE INIT
USE DIVG
USE PRES
USE MASS
USE PART
USE VEGE
USE VELO
USE RAD
USE MEMORY_FUNCTIONS
USE COMP_FUNCTIONS, ONLY : SECOND, WALL_CLOCK_TIME, SHUTDOWN
USE DEVICE_VARIABLES
USE WALL_ROUTINES
USE FIRE
USE CONTROL_FUNCTIONS
USE EVAC

IMPLICIT NONE
 
! Miscellaneous declarations

CHARACTER(255), PARAMETER :: mainid='$Id$'
CHARACTER(255), PARAMETER :: mainrev='$Revision$'
CHARACTER(255), PARAMETER :: maindate='$Date$'
LOGICAL  :: EX,DIAGNOSTICS,FIRST_PASS
INTEGER  :: LO10,NM,IZERO,REVISION_NUMBER,IOS
REAL(EB) :: T_MAX,T_MIN
REAL(EB), ALLOCATABLE, DIMENSION(:,:) :: AINV
CHARACTER(255) :: REVISION_DATE
REAL(EB), ALLOCATABLE, DIMENSION(:) :: T,DT_SYNC,DTNEXT_SYNC
INTEGER, ALLOCATABLE, DIMENSION(:) ::  MESH_STOP_STATUS
LOGICAL, ALLOCATABLE, DIMENSION(:) ::  ACTIVE_MESH
INTEGER NOM,IMIN,IMAX,JMIN,JMAX,KMIN,KMAX,IW
INTEGER, PARAMETER :: N_DROP_ADOPT_MAX=10000
TYPE (MESH_TYPE), POINTER :: M,M4
TYPE (OMESH_TYPE), POINTER :: M2,M3

! Start wall clock timing

WALL_CLOCK_START = WALL_CLOCK_TIME()
 
! Assign a compilation date, version number, revision number

WRITE(VERSION_STRING,'(A)') '5.1.5'

IF (INDEX(mainrev,':',BACK=.TRUE.)>0) THEN
   WRITE(REVISION_DATE,'(A)',IOSTAT=IOS,ERR=5) mainrev(INDEX(mainrev,':')+1:LEN_TRIM(mainrev)-2)
   5 REVISION_NUMBER = 0
   IF (IOS==0) READ(REVISION_DATE,'(I5)') REVISION_NUMBER
   WRITE(REVISION_DATE,'(A)') maindate
   CALL GET_REVISION_NUMBER(REVISION_NUMBER,REVISION_DATE)
   SVN_REVISION_NUMBER = REVISION_NUMBER
   WRITE(COMPILE_DATE,'(A)',IOSTAT=IOS,ERR=10) REVISION_DATE(INDEX(REVISION_DATE,'(')+1:INDEX(REVISION_DATE,')')-1)
   10 IF (IOS>0) COMPILE_DATE = 'null'
ENDIF

! Read input from CHID.data file (All Nodes)

CALL READ_DATA

! Allocate inverse of coarse A matrix and save array for PRESSURE_CORRECTION

IF (PRESSURE_CORRECTION) THEN
   ALLOCATE(AINV(NCGC,NCGC),STAT=IZERO)
   CALL ChkMemErr('MAIN','AINV',IZERO)
   AINV = 0._EB
ENDIF
 
! Open and write to Smokeview file 
 
CALL ASSIGN_FILE_NAMES

CALL EVAC_READ_DATA

CALL WRITE_SMOKEVIEW_FILE
OPEN(LU_SMV,FILE=FN_SMV,FORM='FORMATTED', STATUS='OLD',POSITION='APPEND')

! Write status files

CALL WRITE_STATUS_FILES

! Stop all the processes if this is just a set-up run
 
IF (SET_UP) CALL SHUTDOWN('Stop FDS, Set-up only')
 
! Set up Time array (All Nodes)
 
ALLOCATE(ACTIVE_MESH(NMESHES),STAT=IZERO)
CALL ChkMemErr('MAIN','ACTIVE_MESH',IZERO)
ALLOCATE(T(NMESHES),STAT=IZERO)
CALL ChkMemErr('MAIN','T',IZERO)
ALLOCATE(DT_SYNC(NMESHES),STAT=IZERO)
CALL ChkMemErr('MAIN','DT_SYNC',IZERO)
ALLOCATE(DTNEXT_SYNC(NMESHES),STAT=IZERO)
CALL ChkMemErr('MAIN','DTNEXT_SYNC',IZERO)
ALLOCATE(MESH_STOP_STATUS(NMESHES),STAT=IZERO)
CALL ChkMemErr('MAIN','MESH_STOP_STATUS',IZERO)
T     = T_BEGIN
MESH_STOP_STATUS = NO_STOP
CALL INITIALIZE_GLOBAL_VARIABLES
IF (RADIATION) CALL INIT_RADIATION
DO NM=1,NMESHES
   CALL INITIALIZE_MESH_VARIABLES(NM)
   IF (PROCESS_STOP_STATUS > 0) CALL END_FDS
ENDDO
! Allocate and initialize mesh variable exchange arrays
DO NM=1,NMESHES
   CALL INITIALIZE_MESH_EXCHANGE(NM)
ENDDO
I_MIN = TRANSPOSE(I_MIN)
I_MAX = TRANSPOSE(I_MAX)
J_MIN = TRANSPOSE(J_MIN)
J_MAX = TRANSPOSE(J_MAX)
K_MIN = TRANSPOSE(K_MIN)
K_MAX = TRANSPOSE(K_MAX)
NIC   = TRANSPOSE(NIC)
 
DO NM=1,NMESHES
   CALL DOUBLE_CHECK(NM)
ENDDO
 
! Potentially read data from a previous calculation 
 
DO NM=1,NMESHES
   IF (RESTART) CALL READ_RESTART(T(NM),NM)
ENDDO
 
! Initialize output files containing global data 
 
CALL INITIALIZE_GLOBAL_DUMPS

CALL INIT_EVAC_DUMPS
 
! Initialize output files that are mesh-specific
 
DO NM=1,NMESHES
   CALL INITIALIZE_MESH_DUMPS(NM)
   CALL INITIALIZE_DROPLETS(NM)
   CALL INITIALIZE_RAISED_VEG(NM)
!rm  CALL INITIALIZE_TREES(NM)
   CALL INITIALIZE_EVAC(NM)
   IF (MESH_STOP_STATUS(NM)/=NO_STOP) PROCESS_STOP_STATUS = MESH_STOP_STATUS(NM)
ENDDO

CALL INIT_EVAC_GROUPS
 
! Write out character strings to .smv file
 
CALL WRITE_STRINGS

! Initialize Mesh Exchange Arrays (All Nodes)

CALL MESH_EXCHANGE(0)

! Initialize output files 

IF (.NOT.RESTART) THEN

   ! Make an initial dump of ambient values

   DO NM=1,NMESHES
      CALL UPDATE_OUTPUTS(T(NM),NM)      
      CALL DUMP_MESH_OUTPUTS(T(NM),NM)
   ENDDO
   CALL UPDATE_CONTROLS(T)
   CALL DUMP_GLOBAL_OUTPUTS(T(1))

   ! Check for changes in VENT or OBSTruction control and device status at t=T_BEGIN

   OBST_VENT_LOOP: DO NM=1,NMESHES
      CALL OPEN_AND_CLOSE(T(NM),NM)
   ENDDO OBST_VENT_LOOP

ENDIF

IF (PROCESS_STOP_STATUS > 0) CALL END_FDS

WALL_CLOCK_START_ITERATIONS = WALL_CLOCK_TIME()

!***********************************************************************************************************************************
!                                                     MAIN TIMESTEPPING LOOP
!***********************************************************************************************************************************

MAIN_LOOP: DO  

   ICYC  = ICYC + 1 

   ! Check for program stops

   INQUIRE(FILE=TRIM(CHID)//'.stop',EXIST=EX)
   IF (EX) MESH_STOP_STATUS = USER_STOP
 
   ! Figure out fastest and slowest meshes

   T_MAX = -1000000._EB
   T_MIN =  1000000._EB
   DO NM=1,NMESHES
      T_MIN = MIN(T(NM),T_MIN)
      T_MAX = MAX(T(NM),T_MAX)
      IF (MESH_STOP_STATUS(NM)/=NO_STOP) PROCESS_STOP_STATUS = MESH_STOP_STATUS(NM)
   ENDDO
 
   IF (SYNCHRONIZE) THEN
      DTNEXT_SYNC(1:NMESHES) = MESHES(1:NMESHES)%DTNEXT
      DO NM=1,NMESHES
         IF (SYNC_TIME_STEP(NM)) THEN
            MESHES(NM)%DTNEXT = MINVAL(DTNEXT_SYNC,MASK=SYNC_TIME_STEP)
            T(NM) = MINVAL(T,MASK=SYNC_TIME_STEP)
            ACTIVE_MESH(NM) = .TRUE.
         ELSE
            ACTIVE_MESH(NM) = .FALSE.
            IF (T(NM)+MESHES(NM)%DTNEXT<=T_MAX) ACTIVE_MESH(NM) = .TRUE.
            IF (PROCESS_STOP_STATUS/=NO_STOP) ACTIVE_MESH(NM) = .TRUE.
         ENDIF
      ENDDO
   ELSE
      ACTIVE_MESH = .FALSE.
      DO NM=1,NMESHES
         IF (T(NM)+MESHES(NM)%DTNEXT <= T_MAX) ACTIVE_MESH(NM) = .TRUE.
         IF (PROCESS_STOP_STATUS/=NO_STOP) ACTIVE_MESH(NM) = .TRUE.
      ENDDO
   ENDIF
   DIAGNOSTICS = .FALSE.
   LO10 = LOG10(REAL(MAX(1,ABS(ICYC)),EB))
   IF (MOD(ICYC,10**LO10)==0 .OR. MOD(ICYC,100)==0 .OR. T_MIN>=T_END .OR. PROCESS_STOP_STATUS/=NO_STOP) DIAGNOSTICS = .TRUE.
   
   ! If no meshes are due to be updated, update them all
 
   IF (ALL(.NOT.ACTIVE_MESH)) ACTIVE_MESH = .TRUE.
   CALL EVAC_MAIN_LOOP

   !=============================================================================================================================
   !                                                     PREDICTOR Step
   !=============================================================================================================================

   PREDICTOR = .TRUE.
   CORRECTOR = .FALSE.

   ! Force normal components of velocity to match at interpolated boundaries

   IF (NMESHES>1) THEN
      DO NM=1,NMESHES
         IF (ACTIVE_MESH(NM)) CALL MATCH_VELOCITY(NM)
      ENDDO
   ENDIF

   ! Compute mass and momentum finite differences
   
   COMPUTE_FINITE_DIFFERENCES_1: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_FINITE_DIFFERENCES_1
      MESHES(NM)%DT = MESHES(NM)%DTNEXT
      NTCYC(NM)   = NTCYC(NM) + 1
      CALL INSERT_DROPLETS_AND_PARTICLES(T(NM),NM)
      CALL COMPUTE_VELOCITY_FLUX(T(NM),NM)
      CALL UPDATE_PARTICLES(T(NM),NM)
      IF (FLUX_LIMITER<0 .AND. (.NOT.ISOTHERMAL .OR. N_SPECIES>0)) CALL MASS_FINITE_DIFFERENCES(NM)
   ENDDO COMPUTE_FINITE_DIFFERENCES_1
   
   ! Predict various flow quantities at next time step, and repeat process if there is a time step change

   FIRST_PASS = .TRUE.

   CHANGE_TIME_STEP_LOOP: DO

      COMPUTE_DENSITY_LOOP: DO NM=1,NMESHES
         IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_DENSITY_LOOP
         IF (FLUX_LIMITER>=0) THEN
            CALL DENSITY_TVD(NM)
         ELSE
            IF (.NOT.ISOTHERMAL .OR. N_SPECIES>0) CALL DENSITY(NM)
         ENDIF
      ENDDO COMPUTE_DENSITY_LOOP

      IF (FIRST_PASS .OR. SYNCHRONIZE) CALL MESH_EXCHANGE(1)
 
      COMPUTE_DIVERGENCE_LOOP: DO NM=1,NMESHES
         IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_DIVERGENCE_LOOP
         IF (.NOT.ISOTHERMAL .OR. N_SPECIES>0) CALL WALL_BC(T(NM),NM)
         CALL DIVERGENCE_PART_1(T(NM),NM)
      ENDDO COMPUTE_DIVERGENCE_LOOP

      CALL EXCHANGE_DIVERGENCE_INFO
      
      COMPUTE_PRESSURE_LOOP: DO NM=1,NMESHES
         IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_PRESSURE_LOOP
         CALL DIVERGENCE_PART_2(NM)
         CALL PRESSURE_SOLVER(T(NM),NM)
         CALL EVAC_PRESSURE_LOOP(NM)
      ENDDO COMPUTE_PRESSURE_LOOP
 
      IF (PRESSURE_CORRECTION .AND. (FIRST_PASS .OR. SYNCHRONIZE)) THEN
         CALL MESH_EXCHANGE(2)
         CALL CORRECT_PRESSURE
      ENDIF

      PREDICT_VELOCITY_LOOP: DO NM=1,NMESHES
         IF (.NOT.ACTIVE_MESH(NM)) CYCLE PREDICT_VELOCITY_LOOP
         CALL VELOCITY_PREDICTOR(NM,MESH_STOP_STATUS(NM))
         IF (MESH_STOP_STATUS(NM)==INSTABILITY_STOP) PROCESS_STOP_STATUS = INSTABILITY_STOP
      ENDDO PREDICT_VELOCITY_LOOP

      ! Time step logic

      IF (PROCESS_STOP_STATUS/=NO_STOP) THEN
         DIAGNOSTICS = .TRUE.
         EXIT CHANGE_TIME_STEP_LOOP
      ENDIF

      IF (SYNCHRONIZE .AND. ANY(CHANGE_TIME_STEP)) THEN
         CHANGE_TIME_STEP = .TRUE.
         DT_SYNC(1:NMESHES) = MESHES(1:NMESHES)%DT
         DTNEXT_SYNC(1:NMESHES) = MESHES(1:NMESHES)%DTNEXT
         DO NM=1,NMESHES
            IF (EVACUATION_ONLY(NM)) CHANGE_TIME_STEP(NM) = .FALSE.
            MESHES(NM)%DTNEXT = MINVAL(DTNEXT_SYNC,MASK=SYNC_TIME_STEP)
            MESHES(NM)%DT     = MINVAL(DT_SYNC,MASK=SYNC_TIME_STEP)
         ENDDO
      ENDIF
 
      IF (.NOT.ANY(CHANGE_TIME_STEP)) EXIT CHANGE_TIME_STEP_LOOP
 
      FIRST_PASS = .FALSE.

   ENDDO CHANGE_TIME_STEP_LOOP

   CHANGE_TIME_STEP = .FALSE.
   
   ! Do the tangential velocity boundary conditions

   CALL MESH_EXCHANGE(3)

   VELOCITY_BC_LOOP_1: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE VELOCITY_BC_LOOP_1
      CALL VELOCITY_BC(T(NM),NM)
   ENDDO VELOCITY_BC_LOOP_1

   ! Advance the time

   DO NM=1,NMESHES
      IF (ACTIVE_MESH(NM)) T(NM) = T(NM) + MESHES(NM)%DT
   ENDDO

   !+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
   !                                                      CORRECTOR Step
   !+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

   CORRECTOR = .TRUE.
   PREDICTOR = .FALSE.

   ! Force normal component of predicted velocities to match at interpolated boundaries

   IF (NMESHES>1) THEN
      DO NM=1,NMESHES
         IF (ACTIVE_MESH(NM)) CALL MATCH_VELOCITY(NM)
      ENDDO
   ENDIF

   ! Compute finite differences of predicted quantities

   COMPUTE_FINITE_DIFFERENCES_2: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_FINITE_DIFFERENCES_2
      CALL OPEN_AND_CLOSE(T(NM),NM)
      CALL COMPUTE_VELOCITY_FLUX(T(NM),NM)     
      
      IF (FLUX_LIMITER>=0) THEN
         CALL DENSITY_TVD(NM)
      ELSE
         IF (.NOT.ISOTHERMAL .OR. N_SPECIES>0) THEN
            CALL MASS_FINITE_DIFFERENCES(NM)
            CALL DENSITY(NM)
         ENDIF
      ENDIF
      
      CALL UPDATE_PARTICLES(T(NM),NM)
      CALL RAISED_VEG_MASS_ENERGY_TRANSFER(T(NM),NM)
   ENDDO COMPUTE_FINITE_DIFFERENCES_2

   CALL MESH_EXCHANGE(4) 

   COMPUTE_DIVERGENCE_2: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_DIVERGENCE_2
      IF (.NOT.ISOTHERMAL .OR. N_SPECIES>0) THEN
         IF (N_REACTIONS > 0) CALL COMBUSTION (NM)
         CALL WALL_BC(T(NM),NM)
         CALL COMPUTE_RADIATION(NM)
      ENDIF
      CALL DIVERGENCE_PART_1(T(NM),NM)
   ENDDO COMPUTE_DIVERGENCE_2
     
   CALL EXCHANGE_DIVERGENCE_INFO
   
   COMPUTE_PRESSURE_LOOP_2: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE COMPUTE_PRESSURE_LOOP_2
      CALL DIVERGENCE_PART_2(NM)
      CALL PRESSURE_SOLVER(T(NM),NM)
      CALL EVAC_PRESSURE_LOOP(NM)
   ENDDO COMPUTE_PRESSURE_LOOP_2
   
   IF (PRESSURE_CORRECTION) THEN
      CALL MESH_EXCHANGE(5)
      CALL CORRECT_PRESSURE 
   ENDIF
     
   CORRECT_VELOCITY_LOOP: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE CORRECT_VELOCITY_LOOP
      CALL VELOCITY_CORRECTOR(NM)
      IF (DIAGNOSTICS) CALL CHECK_DIVERGENCE(NM)
   ENDDO CORRECT_VELOCITY_LOOP

   IF (CHECK_VOLUME_FLOW) CALL COMPUTE_VOLUME_FLOW

   ! Exchange velocity and pressure at interpolated boundaries

   CALL MESH_EXCHANGE(6)

   ! Apply tangential velocity boundary conditions and start dumping output data

   VELOCITY_BC_LOOP_2: DO NM=1,NMESHES
      IF (.NOT.ACTIVE_MESH(NM)) CYCLE VELOCITY_BC_LOOP_2
      CALL VELOCITY_BC(T(NM),NM)
      CALL UPDATE_OUTPUTS(T(NM),NM)      
   ENDDO VELOCITY_BC_LOOP_2

   ! Exchange EVAC information among meshes

   CALL EVAC_EXCHANGE

   ! Dump outputs that are tied to individual meshes, like SLCF and BNDF files
   
   CALL UPDATE_CONTROLS(T)
   DO NM=1,NMESHES
      IF (ACTIVE_MESH(NM)) CALL DUMP_MESH_OUTPUTS(T(NM),NM) 
   ENDDO

   ! Dump global quantities like HRR, MASS, and DEViCes. 

   CALL DUMP_GLOBAL_OUTPUTS(MINVAL(T))

   ! Write character strings out to the .smv file
 
   CALL WRITE_STRINGS
   
   ! Dump out diagnostics
 
   IF (DIAGNOSTICS) THEN
      CALL EXCHANGE_DIAGNOSTICS
      CALL WRITE_DIAGNOSTICS(T)
   ENDIF
 
   ! Stop the run
   
   IF (T_MIN>=T_END .OR. PROCESS_STOP_STATUS/=NO_STOP) EXIT MAIN_LOOP
 
   ! Flush Buffers 
   
   IF (MOD(ICYC,10)==0 .AND. FLUSH_FILE_BUFFERS) THEN
      CALL FLUSH_GLOBAL_BUFFERS
      CALL FLUSH_EVACUATION_BUFFERS
      DO NM=1,NMESHES
         CALL FLUSH_LOCAL_BUFFERS(NM)
      ENDDO
   ENDIF

ENDDO MAIN_LOOP
 
!***********************************************************************************************************************************
!                                                        END OF TIMESTEP
!***********************************************************************************************************************************
 
TUSED(1,1:NMESHES) = SECOND() - TUSED(1,1:NMESHES)
 
CALL TIMINGS

CALL END_FDS
 
CONTAINS


SUBROUTINE END_FDS

SELECT CASE(PROCESS_STOP_STATUS)
   CASE(NO_STOP)
      WRITE(LU_ERR,'(A)') 'STOP: FDS completed successfully'
      IF (STATUS_FILES) CLOSE(LU_NOTREADY,STATUS='DELETE')
   CASE(INSTABILITY_STOP)
      WRITE(LU_ERR,'(A)') 'STOP: Numerical Instability'
   CASE(USER_STOP)
      WRITE(LU_ERR,'(A)') 'STOP: FDS stopped by user'
   CASE(SETUP_STOP)
      WRITE(LU_ERR,'(A)') 'STOP: FDS improperly set-up'
END SELECT

STOP
 
END SUBROUTINE END_FDS

 
SUBROUTINE EXCHANGE_DIVERGENCE_INFO

! Exchange information mesh to mesh used to compute global pressure integrals

INTEGER :: IPZ
REAL(EB) :: DSUM_ALL,PSUM_ALL,USUM_ALL

DO IPZ=1,N_ZONE
   DSUM_ALL = 0._EB
   PSUM_ALL = 0._EB
   USUM_ALL = 0._EB
   DO NM=1,NMESHES
      IF(EVACUATION_ONLY(NM)) CYCLE  ! Issue 257 bug fix
      DSUM_ALL = DSUM_ALL + DSUM(IPZ,NM)
      PSUM_ALL = PSUM_ALL + PSUM(IPZ,NM)
      USUM_ALL = USUM_ALL + USUM(IPZ,NM)
   ENDDO
!!$   DSUM(IPZ,1:NMESHES) = DSUM_ALL
!!$   PSUM(IPZ,1:NMESHES) = PSUM_ALL
!!$   USUM(IPZ,1:NMESHES) = USUM_ALL
   DO NM=1,NMESHES
      IF(EVACUATION_ONLY(NM)) CYCLE  ! Issue 257 bug fix
      DSUM(IPZ,NM) = DSUM_ALL
      PSUM(IPZ,NM) = PSUM_ALL
      USUM(IPZ,NM) = USUM_ALL
   ENDDO
ENDDO

END SUBROUTINE EXCHANGE_DIVERGENCE_INFO
 

SUBROUTINE INITIALIZE_MESH_EXCHANGE(NM)
 
! Create arrays by which info is to exchanged across meshes
 
INTEGER IMIN,IMAX,JMIN,JMAX,KMIN,KMAX,NOM,IOR,IW,N
INTEGER, INTENT(IN) :: NM
TYPE (MESH_TYPE), POINTER :: M2,M
LOGICAL FOUND
 
M=>MESHES(NM)
 
ALLOCATE(M%OMESH(NMESHES))
 
OTHER_MESH_LOOP: DO NOM=1,NMESHES
 
   IF (NOM==NM) CYCLE OTHER_MESH_LOOP
 
   M2=>MESHES(NOM)
   IMIN=0
   JMIN=0
   KMIN=0
   IMAX=M2%IBP1
   JMAX=M2%JBP1
   KMAX=M2%KBP1
   NIC(NOM,NM) = 0
   FOUND = .FALSE.

   IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP ! Issue 257 bug fix

   SEARCH_LOOP: DO IW=1,M%NEWC
      IF (M%IJKW(9,IW)/=NOM) CYCLE SEARCH_LOOP
      NIC(NOM,NM) = NIC(NOM,NM) + 1
      FOUND = .TRUE.
      IOR = M%IJKW(4,IW)
      SELECT CASE(IOR)
         CASE( 1)
            IMIN=MAX(IMIN,M%IJKW(10,IW)-1)
         CASE(-1) 
            IMAX=MIN(IMAX,M%IJKW(13,IW))
         CASE( 2) 
            JMIN=MAX(JMIN,M%IJKW(11,IW)-1)
         CASE(-2) 
            JMAX=MIN(JMAX,M%IJKW(14,IW))
         CASE( 3) 
            KMIN=MAX(KMIN,M%IJKW(12,IW)-1)
         CASE(-3) 
            KMAX=MIN(KMAX,M%IJKW(15,IW))
      END SELECT
   ENDDO SEARCH_LOOP
 
   IF ( M2%XS>=M%XS .AND. M2%XF<=M%XF .AND. M2%YS>=M%YS .AND. M2%YF<=M%YF .AND. M2%ZS>=M%ZS .AND. M2%ZF<=M%ZF ) FOUND = .TRUE.
 
   IF (.NOT.FOUND) CYCLE OTHER_MESH_LOOP
 
   I_MIN(NOM,NM) = IMIN
   I_MAX(NOM,NM) = IMAX
   J_MIN(NOM,NM) = JMIN
   J_MAX(NOM,NM) = JMAX
   K_MIN(NOM,NM) = KMIN
   K_MAX(NOM,NM) = KMAX
 
   ALLOCATE(M%OMESH(NOM)% RHO(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%RHOS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%   H(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%   U(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%   V(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%   W(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%  US(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%  VS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%  WS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%DUDT(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%DVDT(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   ALLOCATE(M%OMESH(NOM)%DWDT(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX))
   IF (N_SPECIES>0) THEN
      ALLOCATE(M%OMESH(NOM)%  YY(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,N_SPECIES))
      ALLOCATE(M%OMESH(NOM)% YYS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,N_SPECIES))
   ENDIF

   M%OMESH(NOM)% RHO = RHOA
   M%OMESH(NOM)%RHOS = RHOA
   M%OMESH(NOM)%H    = 0._EB
   M%OMESH(NOM)%U    = U0
   M%OMESH(NOM)%V    = V0
   M%OMESH(NOM)%W    = W0
   M%OMESH(NOM)%US   = U0
   M%OMESH(NOM)%VS   = V0
   M%OMESH(NOM)%WS   = W0
   M%OMESH(NOM)%DUDT = 0._EB
   M%OMESH(NOM)%DVDT = 0._EB
   M%OMESH(NOM)%DWDT = 0._EB
   DO N=1,N_SPECIES
      M%OMESH(NOM)%YY(:,:,:,N)  = SPECIES(N)%YY0
      M%OMESH(NOM)%YYS(:,:,:,N) = SPECIES(N)%YY0
   ENDDO
 
   ! Wall arrays
 
   ALLOCATE(M%OMESH(NOM)%BOUNDARY_TYPE(0:M2%NEWC))
   M%OMESH(NOM)%BOUNDARY_TYPE(0:M2%NEWC) = M2%BOUNDARY_TYPE(0:M2%NEWC)
   ALLOCATE(M%OMESH(NOM)%IJKW(15,M2%NEWC))
   M%OMESH(NOM)%IJKW = M2%IJKW(:,1:M2%NEWC)
    
   ALLOCATE(M%OMESH(NOM)%WALL(0:M2%NEWC))
 
   ! Particle and Droplet Orphan Arrays
 
   IF (DROPLET_FILE) THEN
      M%OMESH(NOM)%N_DROP_ORPHANS = 0
      M%OMESH(NOM)%N_DROP_ORPHANS_DIM = 1000
      ALLOCATE(M%OMESH(NOM)%DROPLET(M%OMESH(NOM)%N_DROP_ORPHANS_DIM),STAT=IZERO)
      CALL ChkMemErr('INIT','DROPLET',IZERO)
   ENDIF
 
ENDDO OTHER_MESH_LOOP
 
END SUBROUTINE INITIALIZE_MESH_EXCHANGE
 
 

SUBROUTINE DOUBLE_CHECK(NM)
 
! Double check exchange pairs
 
INTEGER NOM
INTEGER, INTENT(IN) :: NM
TYPE (MESH_TYPE), POINTER :: M2,M
 
M=>MESHES(NM)
 
OTHER_MESH_LOOP: DO NOM=1,NMESHES
   IF (NOM==NM) CYCLE OTHER_MESH_LOOP
   IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP ! Issue 257 bug fix
   IF (NIC(NM,NOM)==0 .AND. NIC(NOM,NM)>0) THEN
      M2=>MESHES(NOM)
      ALLOCATE(M%OMESH(NOM)%IJKW(15,M2%NEWC))
      ALLOCATE(M%OMESH(NOM)%BOUNDARY_TYPE(0:M2%NEWC))
      ALLOCATE(M%OMESH(NOM)%WALL(0:M2%NEWC))
   ENDIF
ENDDO OTHER_MESH_LOOP
 
END SUBROUTINE DOUBLE_CHECK
 
 
SUBROUTINE MESH_EXCHANGE(CODE)

! Exchange Information between Meshes

USE RADCONS, ONLY :NSB,NRA 
REAL(EB) :: TNOW 
INTEGER, INTENT(IN) :: CODE
INTEGER :: NM,II,JJ,KK
 
TNOW = SECOND()
 
MESH_LOOP: DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE MESH_LOOP ! Issue 257 bug fix
   OTHER_MESH_LOOP: DO NOM=1,NMESHES
 
      IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP ! Issue 257 bug fix
      IF (CODE==0 .AND. NIC(NOM,NM)<1 .AND. NIC(NM,NOM)>0 .AND. I_MIN(NOM,NM)<0 .AND. RADIATION) THEN
         M =>MESHES(NM)
         M2=>MESHES(NOM)%OMESH(NM)
         DO IW=1,M%NEWC
            IF (M%IJKW(9,IW)==NOM) THEN
               ALLOCATE(M2%WALL(IW)%ILW(NRA,NSB))
               M2%WALL(IW)%ILW = SIGMA*TMPA4*RPI
            ENDIF
         ENDDO
      ENDIF
 
      IF (NIC(NOM,NM)==0 .AND. NIC(NM,NOM)==0) CYCLE OTHER_MESH_LOOP

      IF (CODE>0 .AND. (.NOT.ACTIVE_MESH(NM) .OR. .NOT.ACTIVE_MESH(NOM))) CYCLE OTHER_MESH_LOOP

      IF (DEBUG) WRITE(LU_ERR,*) NOM,' receiving data from ',NM,' code=',CODE
 
      M =>MESHES(NM)
      M2=>MESHES(NOM)%OMESH(NM)
      M3=>MESHES(NM)%OMESH(NOM)
      M4=>MESHES(NOM)
 
      IMIN = I_MIN(NOM,NM)
      IMAX = I_MAX(NOM,NM)
      JMIN = J_MIN(NOM,NM)
      JMAX = J_MAX(NOM,NM)
      KMIN = K_MIN(NOM,NM)
      KMAX = K_MAX(NOM,NM)
 
      ! Set up arrays needed for radiation exchange

      IF (CODE==0 .AND. RADIATION) THEN
         DO IW=1,M%NEWC
         IF (M%IJKW(9,IW)==NOM) THEN
            ALLOCATE(M2%WALL(IW)%ILW(NRA,NSB))
            M2%WALL(IW)%ILW = SIGMA*TMPA4*RPI
            ENDIF
         ENDDO
      ENDIF

      ! Exchange density and species mass fraction in PREDICTOR stage
 
      IF (CODE==1 .AND. NIC(NOM,NM)>0) THEN
         M2%RHOS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)= M%RHOS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         IF (N_SPECIES>0) M2%YYS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,1:N_SPECIES)= M%YYS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,1:N_SPECIES)
      ENDIF 

      ! Exchange velocity flux info for PRESSURE_COORECTION
 
      IF ((CODE==2 .OR. CODE==5) .AND. NIC(NOM,NM)>0) THEN
         DO IW=1,M4%NEWC
            IF (M3%IJKW(9,IW)/=NM) CYCLE 
            DO KK=M3%IJKW(12,IW),M3%IJKW(15,IW)
               DO JJ=M3%IJKW(11,IW),M3%IJKW(14,IW)
                  DO II=M3%IJKW(10,IW),M3%IJKW(13,IW)
                     SELECT CASE(M3%IJKW(4,IW))
                        CASE( 1)
                           M2%DUDT(II,JJ,KK)   = -M%FVX(II,JJ,KK)-(M%H(II+1,JJ,KK)-M%H(II,JJ,KK))*M%RDXN(II)
                        CASE(-1)
                           M2%DUDT(II-1,JJ,KK) = -M%FVX(II-1,JJ,KK)-(M%H(II,JJ,KK)-M%H(II-1,JJ,KK))*M%RDXN(II-1)
                        CASE( 2)
                           M2%DVDT(II,JJ,KK)   = -M%FVY(II,JJ,KK)-(M%H(II,JJ+1,KK)-M%H(II,JJ,KK))*M%RDYN(JJ)
                        CASE(-2)
                           M2%DVDT(II,JJ-1,KK) = -M%FVY(II,JJ-1,KK)-(M%H(II,JJ,KK)-M%H(II,JJ-1,KK))*M%RDYN(JJ-1)
                        CASE( 3)
                           M2%DWDT(II,JJ,KK)   = -M%FVZ(II,JJ,KK)-(M%H(II,JJ,KK+1)-M%H(II,JJ,KK))*M%RDZN(KK)
                        CASE(-3)
                           M2%DWDT(II,JJ,KK-1) = -M%FVZ(II,JJ,KK-1)-(M%H(II,JJ,KK)-M%H(II,JJ,KK-1))*M%RDZN(KK-1)
                     END SELECT
                  ENDDO
               ENDDO
            ENDDO
         ENDDO
      ENDIF

      ! Exchange pressures at end of PREDICTOR stage

      IF (CODE==3 .AND. NIC(NOM,NM)>0) THEN
         M2%H(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX) =  M%H(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         M2%US(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%US(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         M2%VS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%VS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         M2%WS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%WS(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
      ENDIF 
 
      ! Exchange density and species mass fraction in CORRECTOR stage
      
      IF (CODE==4 .AND. NIC(NOM,NM)>0) THEN
         M2%RHO(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)= M%RHO(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         IF (N_SPECIES>0) M2%YY(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,1:N_SPECIES)= M%YY(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX,1:N_SPECIES)
      ENDIF

      ! Exchange BOUNDARY_TYPE

      IF (CODE==0 .OR. CODE==6) M2%BOUNDARY_TYPE(0:M%NEWC) = M%BOUNDARY_TYPE(0:M%NEWC)

      ! Exchange pressures and velocities at end of CORRECTOR stage

      IF (CODE==6 .AND. NIC(NOM,NM)>0) THEN
         M2%H(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%H(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         M2%U(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%U(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         M2%V(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%V(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
         M2%W(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)=  M%W(IMIN:IMAX,JMIN:JMAX,KMIN:KMAX)
      ENDIF

      ! Exchange radiation at the end of the CORRECTOR stage

      IF (CODE==6 .AND. RADIATION .AND. NIC(NOM,NM)>0) THEN
         DO IW=1,M4%NEWC
            IF (M4%IJKW(9,IW)==NM) M4%WALL(IW)%ILW(1:NRA,1:NSB) = M3%WALL(IW)%ILW(1:NRA,1:NSB)
         ENDDO
      ENDIF
 
      ! Get Number of Droplet Orphans
 
      IF (DROPLET_FILE) THEN 
         M2%N_DROP_ADOPT = MIN(M3%N_DROP_ORPHANS,N_DROP_ADOPT_MAX)
         IF (M4%NLP+M2%N_DROP_ADOPT>M4%NLPDIM) CALL RE_ALLOCATE_DROPLETS(1,NOM,0,N_DROP_ADOPT_MAX)
      ENDIF
 
      ! Sending/Receiving Droplet Buffer Arrays
 
      IF_DROPLETS: IF (DROPLET_FILE) THEN 
         IF_DROPLETS_SENT: IF (M2%N_DROP_ADOPT>0) THEN
            M4%DROPLET(M4%NLP+1:M4%NLP+M2%N_DROP_ADOPT)=  M3%DROPLET(1:M2%N_DROP_ADOPT) 
            M4%NLP = M4%NLP + M2%N_DROP_ADOPT
            M3%N_DROP_ORPHANS = 0
         ENDIF IF_DROPLETS_SENT
      ENDIF IF_DROPLETS
 
   ENDDO OTHER_MESH_LOOP
ENDDO MESH_LOOP
 
TUSED(11,:)=TUSED(11,:) + SECOND() - TNOW
END SUBROUTINE MESH_EXCHANGE
 

SUBROUTINE EXCHANGE_DIAGNOSTICS
 
INTEGER  :: NM,NECYC,I
REAL(EB) :: T_SUM,TNOW
 
TNOW = SECOND()
 
MESH_LOOP: DO NM=1,NMESHES
   T_SUM = 0._EB
   SUM_LOOP: DO I=2,N_TIMERS_DIM
      T_SUM = T_SUM + TUSED(I,NM)
   ENDDO SUM_LOOP
   NECYC          = MAX(1,NTCYC(NM)-NCYC(NM))
   T_PER_STEP(NM) = (T_SUM-T_ACCUM(NM))/REAL(NECYC,EB)
   T_ACCUM(NM)    = T_SUM
   NCYC(NM)       = NTCYC(NM)
ENDDO MESH_LOOP
 
TUSED(11,:) = TUSED(11,:) + SECOND() - TNOW
END SUBROUTINE EXCHANGE_DIAGNOSTICS
 

SUBROUTINE CORRECT_PRESSURE
 
USE MATH_FUNCTIONS, ONLY : GAUSSJ
REAL(EB) :: A(NCGC,NCGC),B(NCGC),TNOW
INTEGER :: IERROR,NM
 
TNOW = SECOND()

A = 0._EB
B = 0._EB
 
MESH_LOOP_2: DO NM=1,NMESHES
   CALL COMPUTE_A_B(A,B,NM)
ENDDO MESH_LOOP_2

IF (RECOMPUTE_A) THEN
   CALL GAUSSJ(A,NCGC,NCGC,B,1,1,IERROR)
   IF (IERROR>0) WRITE(LU_ERR,*) ' COMPUTE B IERROR= ',IERROR
   AINV = A  ! store inverse of A matrix
   RECOMPUTE_A = .FALSE.
ELSE
   B = MATMUL(AINV,B)
ENDIF

MESH_LOOP_3: DO NM=1,NMESHES
CALL COMPUTE_CORRECTION_PRESSURE(B,NM)
ENDDO MESH_LOOP_3
 
TUSED(5,:) = TUSED(5,:) + SECOND() - TNOW
END SUBROUTINE CORRECT_PRESSURE



SUBROUTINE COMPUTE_VOLUME_FLOW

REAL(EB) :: VDOT(NMESHES,NMESHES),ERROR
TYPE (MESH_TYPE), POINTER :: M
INTEGER :: NM,II,JJ,KK,IOR,IW,NOM

VDOT = 0._EB
DO NM=1,NMESHES
   M=>MESHES(NM)
   DO IW=1,M%NEWC
      IF (M%BOUNDARY_TYPE(IW)==INTERPOLATED_BOUNDARY) THEN
         NOM = M%IJKW(9,IW)
         II  = M%IJKW(1,IW)
         JJ  = M%IJKW(2,IW)
         KK  = M%IJKW(3,IW)
         IOR = M%IJKW(4,IW)
         SELECT CASE(IOR)
            CASE( 1)
               VDOT(NM,NOM) = VDOT(NM,NOM) + M%DY(JJ)*M%DZ(KK)*M%U(0,JJ,KK)
            CASE(-1)
               VDOT(NM,NOM) = VDOT(NM,NOM) + M%DY(JJ)*M%DZ(KK)*M%U(M%IBAR,JJ,KK)
            CASE( 2)
               VDOT(NM,NOM) = VDOT(NM,NOM) + M%DX(II)*M%DZ(KK)*M%V(II,0,KK)
            CASE(-2)
               VDOT(NM,NOM) = VDOT(NM,NOM) + M%DX(II)*M%DZ(KK)*M%V(II,M%JBAR,KK)
            CASE( 3)
               VDOT(NM,NOM) = VDOT(NM,NOM) + M%DX(II)*M%DY(JJ)*M%W(II,JJ,0)
            CASE(-3)
               VDOT(NM,NOM) = VDOT(NM,NOM) + M%DX(II)*M%DY(JJ)*M%W(II,JJ,M%KBAR)
         END SELECT
      ENDIF
   ENDDO
ENDDO

DO NM=1,NMESHES
   DO NOM=1,NMESHES
         ERROR = 2._EB*ABS(VDOT(NM,NOM)-VDOT(NOM,NM))/(ABS(VDOT(NM,NOM)+VDOT(NOM,NM))+1.E-10_EB)
         IF (NM<NOM .AND. ERROR>1.E-5_EB) THEN
            WRITE(LU_ERR,'(A,I2,A,I2,A,E12.6)') 'Volume Flow Error, Meshes ',NM,' and ',NOM,' = ',ERROR
         ENDIF
   ENDDO
ENDDO
 
END SUBROUTINE COMPUTE_VOLUME_FLOW

SUBROUTINE WRITE_STRINGS
 
! Write character strings out to the .smv file

INTEGER :: N,NM
 
MESH_LOOP: DO NM=1,NMESHES
   DO N=1,MESHES(NM)%N_STRINGS
      WRITE(LU_SMV,'(A)') TRIM(MESHES(NM)%STRING(N))
   ENDDO
   MESHES(NM)%N_STRINGS = 0
ENDDO MESH_LOOP
 
END SUBROUTINE WRITE_STRINGS

SUBROUTINE DUMP_GLOBAL_OUTPUTS(T)
USE COMP_FUNCTIONS, ONLY :SECOND
REAL(EB), INTENT(IN) :: T
REAL(EB) :: TNOW

TNOW = SECOND()

! Dump out HRR info

IF (T>=HRR_CLOCK .AND. MINVAL(HRR_COUNT,MASK=.NOT.EVACUATION_ONLY)>0._EB) THEN
   CALL DUMP_HRR(T)
   HRR_CLOCK = HRR_CLOCK + DT_HRR
   HRR_SUM   = 0.
   RHRR_SUM  = 0.
   CHRR_SUM  = 0.
   FHRR_SUM  = 0.
   MLR_SUM   = 0.
   HRR_COUNT = 0.
ENDIF

! Dump out Evac info

CALL EVAC_CSV(T)

! Dump out Mass info

IF (T>=MINT_CLOCK .AND. MINVAL(MINT_COUNT,MASK=.NOT.EVACUATION_ONLY)>0._EB) THEN
   CALL DUMP_MASS(T)
   MINT_CLOCK = MINT_CLOCK + DT_MASS
   MINT_SUM   = 0._EB
   MINT_COUNT = 0._EB
ENDIF

! Dump out DEViCe data

IF (T >= DEVC_CLOCK) THEN
   IF (MINVAL(DEVICE(1:N_DEVC)%COUNT)/=0) THEN
      CALL DUMP_DEVICES(T)
      DEVC_CLOCK = DEVC_CLOCK + DT_DEVC
      DEVICE(1:N_DEVC)%VALUE = 0.
      DEVICE(1:N_DEVC)%COUNT = 0
   ENDIF
ENDIF

! Dump out ConTRoL data

IF (T >= CTRL_CLOCK) THEN
   CALL DUMP_CONTROLS(T)
   CTRL_CLOCK = CTRL_CLOCK + DT_CTRL
ENDIF

TUSED(7,1) = TUSED(7,1) + SECOND() - TNOW
   
END SUBROUTINE DUMP_GLOBAL_OUTPUTS


SUBROUTINE EVAC_READ_DATA
IMPLICIT NONE
 
! Read input for EVACUATION routines
 
IF (.Not. ANY(EVACUATION_GRID)) N_EVAC = 0
IF (ANY(EVACUATION_GRID)) CALL READ_EVAC

END SUBROUTINE EVAC_READ_DATA

SUBROUTINE INITIALIZE_EVAC(NM)
IMPLICIT NONE
 
! Initialize evacuation meshes
 
INTEGER, INTENT(IN) :: NM
 
IF (ANY(EVACUATION_GRID)) CALL INITIALIZE_EVACUATION(NM,MESH_STOP_STATUS(NM))
IF (EVACUATION_GRID(NM)) PART_CLOCK(NM) = T_EVAC + DT_PART
IF (EVACUATION_GRID(NM)) CALL DUMP_EVAC(T_EVAC,NM)
IF (ANY(EVACUATION_GRID)) ICYC = -EVAC_TIME_ITERATIONS

END SUBROUTINE INITIALIZE_EVAC

SUBROUTINE INIT_EVAC_DUMPS
IMPLICIT NONE
 
! Initialize evacuation dumps
 
T_EVAC  = - EVAC_DT_FLOWFIELD*EVAC_TIME_ITERATIONS
T_EVAC_SAVE = T_EVAC
IF (ANY(EVACUATION_GRID)) CALL INITIALIZE_EVAC_DUMPS

END SUBROUTINE INIT_EVAC_DUMPS

SUBROUTINE EVAC_CSV(T)
IMPLICIT NONE
REAL(EB), INTENT(IN) :: T
 
! Dump out Evac info
 
IF (T>=EVAC_CLOCK .AND. ANY(EVACUATION_GRID)) THEN
   CALL DUMP_EVAC_CSV(T)
   EVAC_CLOCK = EVAC_CLOCK + DT_HRR
ENDIF

END SUBROUTINE EVAC_CSV

SUBROUTINE EVAC_EXCHANGE
IMPLICIT NONE
LOGICAL EXCHANGE_EVACUATION
 
! Fire mesh information ==> Evac meshes
 
IF (.NOT.ANY(EVACUATION_GRID)) RETURN
IF (ANY(EVACUATION_GRID)) CALL EVAC_MESH_EXCHANGE(T_EVAC,T_EVAC_SAVE,I_EVAC,ICYC,EXCHANGE_EVACUATION,2)

END SUBROUTINE EVAC_EXCHANGE

SUBROUTINE EVAC_PRESSURE_LOOP(NM)
IMPLICIT NONE
 
! Evacuation flow field calculation
 
INTEGER, INTENT(IN) :: NM
INTEGER :: N
 
IF (EVACUATION_ONLY(NM)) THEN
   PRESSURE_ITERATION_LOOP: DO N=1,EVAC_PRESSURE_ITERATIONS
      CALL NO_FLUX
      CALL PRESSURE_SOLVER(T(NM),NM)
   ENDDO PRESSURE_ITERATION_LOOP
END IF

END SUBROUTINE EVAC_PRESSURE_LOOP

SUBROUTINE EVAC_MAIN_LOOP
IMPLICIT NONE
 
! Call evacuation routine and adjust time steps for evac meshes
 
REAL(EB) :: T_FIRE, FIRE_DT
 
IF (.NOT.ANY(EVACUATION_GRID)) RETURN
 
IF (ANY(EVACUATION_ONLY).AND.(ICYC <= 0)) ACTIVE_MESH = .FALSE.
EVAC_DT = EVAC_DT_STEADY_STATE
IF (ICYC < 1) EVAC_DT = EVAC_DT_FLOWFIELD
T_FIRE = T_EVAC + EVAC_DT
IF (ICYC > 0) THEN
   IF (.NOT.ALL(EVACUATION_ONLY)) THEN
      T_FIRE = MINVAL(T,MASK= (.NOT.EVACUATION_ONLY).AND.ACTIVE_MESH)
      DTNEXT_SYNC(1:NMESHES) = MESHES(1:NMESHES)%DTNEXT
      FIRE_DT = MINVAL(DTNEXT_SYNC,MASK= (.NOT.EVACUATION_ONLY).AND.ACTIVE_MESH)
      T_FIRE = T_FIRE + FIRE_DT
   ENDIF
ENDIF
EVAC_TIME_STEP_LOOP: DO WHILE (T_EVAC < T_FIRE)
   T_EVAC = T_EVAC + EVAC_DT
   CALL PREPARE_TO_EVACUATE(ICYC)
   DO NM=1,NMESHES
      IF (EVACUATION_ONLY(NM)) THEN
         ACTIVE_MESH(NM) = .FALSE.
         CHANGE_TIME_STEP(NM) = .FALSE.
         MESHES(NM)%DT     = EVAC_DT
         MESHES(NM)%DTNEXT = EVAC_DT
         T(NM)  = T_EVAC
         IF (ICYC <= 1 .And. .Not. BTEST(I_EVAC,2) ) THEN
            IF (ICYC <= 0) ACTIVE_MESH(NM) = .TRUE.
            IF (ICYC <= 0) T(NM) = T_EVAC + EVAC_DT_FLOWFIELD*EVAC_TIME_ITERATIONS - EVAC_DT
         ENDIF
         IF (EVACUATION_GRID(NM) ) THEN
            CALL EVACUATE_HUMANS(T_EVAC,NM,ICYC)
            IF (T_EVAC >= PART_CLOCK(NM)) THEN
               CALL DUMP_EVAC(T_EVAC,NM)
               DO
                  PART_CLOCK(NM) = PART_CLOCK(NM) + DT_PART
                  IF (PART_CLOCK(NM) >= T_EVAC) EXIT
               ENDDO
            ENDIF
         ENDIF
      ENDIF
   ENDDO
   IF (ICYC < 1) EXIT EVAC_TIME_STEP_LOOP
ENDDO EVAC_TIME_STEP_LOOP

END SUBROUTINE EVAC_MAIN_LOOP

SUBROUTINE GET_REVISION_NUMBER(REV_NUMBER,REV_DATE)
USE isodefs, ONLY : GET_REV_smvv
USE POIS, ONLY : GET_REV_pois
USE VEGE, ONLY : GET_REV_vege
USE COMP_FUNCTIONS, ONLY : GET_REV_func
USE MESH_POINTERS, ONLY : GET_REV_mesh
USE RADCALV, ONLY : GET_REV_irad
USE DCDFLIB, ONLY : GET_REV_ieva
INTEGER,INTENT(INOUT) :: REV_NUMBER
CHARACTER(255),INTENT(INOUT) :: REV_DATE
INTEGER :: MODULE_REV
CHARACTER(255) :: MODULE_DATE

CALL GET_REV_cons(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_ctrl(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_devc(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_divg(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_dump(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_evac(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_fire(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_func(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_ieva(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_init(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_irad(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_mass(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_mesh(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_part(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_pois(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_prec(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_pres(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_radi(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_read(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_smvv(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_type(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_vege(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_velo(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF
CALL GET_REV_wall(MODULE_REV,MODULE_DATE)
IF (MODULE_REV > REV_NUMBER) THEN
   REV_NUMBER = MODULE_REV
   WRITE(REV_DATE,'(A)') MODULE_DATE
ENDIF

END SUBROUTINE GET_REVISION_NUMBER
 
END PROGRAM FDS
