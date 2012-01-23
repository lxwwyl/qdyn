!Calculate stress etc.

module fault_stress

  use fftsg, only : OouraFFT_type

  implicit none
  private

  type kernel_2D_fft
    double precision, dimension(:), allocatable :: kernel
    integer :: nnfft, finite
    type (OouraFFT_type) :: m_fft
  end type kernel_2D_fft

  type kernel_3D
    double precision, dimension(:,:), allocatable :: kernel
  end type kernel_3D

  type kernel_3D_fft
    integer :: nxfft, nw, nx
    double precision, dimension(:,:,:), allocatable :: kernel
    type (OouraFFT_type) :: m_fft
  end type kernel_3D_fft

  type kernel_type
    integer :: kind = 0
    double precision :: k1
    type (kernel_2D_fft), pointer :: k2f
    type (kernel_3D), pointer :: k3
    type (kernel_3D_fft), pointer :: k3f
  end type kernel_type

  public :: init_kernel, compute_stress, kernel_type

contains
! K is stiffness, different in sign with convention in Dieterich (1992)
! compute shear stress rate from elastic interactions
!   tau = - K*slip 
!   dtau_dt = - K*slip_velocity 
!
! To account for steady plate velocity, the input velocity must be v-vpl:
!   tau = - K*( slip - Vpl*t ) 
!   dtau_dt = - K*( v - Vpl )

!=============================================================
! JPA to do: refactor: split this into several subroutines
subroutine init_kernel(lambda,mu,m,k)
  
  use constants, only : PI 
  use mesh, only : mesh_type
  use okada, only : compute_kernel
  use fftsg, only : my_rdft

  double precision, intent(in) :: lambda,mu
  type(mesh_type), intent(in) :: m
  type(kernel_type), intent(inout) :: k

  double precision :: tau_co, wl2, tau
  double precision :: y_src, z_src, dip_src, dw_src 
  double precision :: y_obs, z_obs, dip_obs
  double precision, allocatable :: tmp(:)   ! for FFT
  integer :: i, j, ii, jj, n, nn, IRET

  write(6,*) 'Intializing kernel: ...'

  select case (k%kind)

  case(1) ! 1D
    write(6,*) 'Single degree-of-freedom spring-block system'
    k%k1 = mu/m%Lfault

  case(2) ! 2D
    k%k2f%nnfft = (k%k2f%finite+1)*m%nn 
    allocate (k%k2f%kernel(k%k2f%nnfft))

    write(6,*) 'FFT applied'

    if (k%k2f%finite == 0) then
      tau_co = PI*mu/m%Lfault *2.d0/m%nn
      wl2 = (m%Lfault/m%W)**2
      do i=0,m%nn/2-1
        k%k2f%kernel(2*i+1) = tau_co*sqrt(i*i+wl2)
        k%k2f%kernel(2*i+2) = k%k2f%kernel(2*i+1)
      enddo
      k%k2f%kernel(2) = tau_co*sqrt(m%nn**2/4.d0+wl2) ! Nyquist
       
    elseif (k%k2f%finite == 1) then
      !- Read coefficient I(n) from pre-calculated file.
      open(57,file='~/2D_RUPTURE/STATIC/Matlab/kernel_I_32768.tab')
      if (k%k2f%nnfft/2>32768) stop 'Finite kernel table is too small'
      do i=1,k%k2f%nnfft/2-1
        read(57,*) k%k2f%kernel(2*i+1)
      enddo
      read(57,*) k%k2f%kernel(2) ! Nyquist
      close(57)
      ! The factor 2/N comes from the inverse FFT convention
      tau_co = PI*mu / (2d0*m%Lfault) *2.d0/k%k2f%nnfft
      k%k2f%kernel(1) = 0d0
      k%k2f%kernel(2) = tau_co*dble(k%k2f%nnfft/2)*k%k2f%kernel(2)
      do i = 1,k%k2f%nnfft/2-1
        k%k2f%kernel(2*i+1) = tau_co*dble(i)*k%k2f%kernel(2*i+1)
        k%k2f%kernel(2*i+2) = k%k2f%kernel(2*i+1)
      enddo
    end if

  case(3) ! 3D with FFT along-strike
    write(6,*) 'Generating 3D kernel...'
    write(6,*) 'OouraFFT applied along-strike'
    k%k3f%nw = m%nw
    k%k3f%nx = m%nx
    k%k3f%nxfft = 2*m%nx ! fft convolution requires twice longer array
    allocate(k%k3f%kernel(m%nw,m%nw,k%k3f%nxfft))
    allocate(tmp(k%k3f%nxfft))
    ! assumes faster index runs along-strike
    do n=1,m%nw
      nn = (n-1)*m%nx+1
      y_src = m%y(nn)
      z_src = m%z(nn)
      dip_src = m%dip(nn)
      dw_src = m%dw(n)
      do j=1,m%nw
        jj = (j-1)*m%nx+1
        y_obs = m%y(jj)
        z_obs = m%z(jj)
        dip_obs = m%dip(jj)
        do i=-m%nx+1,m%nx
          call compute_kernel(lambda,mu, &
                  i*m%dx, y_src, z_src, dip_src, m%dx, dw_src,   &
                  0d0, y_obs, z_obs, dip_obs, &
                  IRET,tau)
          ii = i+1
          ! wrap up the negative relative-x-positions in the second half of the array
          ! to comply with conventions of fft convolution
          if (i<0) ii = ii + k%k3f%nxfft  
          tmp(ii) = tau
        enddo
        call my_rdft(1,tmp,k%k3f%m_fft)
        k%k3f%kernel(j,n,:) = tmp / dble(m%nx)
      enddo
    enddo
  
  case(4) ! 3D no fft
    write(6,*) 'Generating 3D kernel...'
    write(6,*) 'NO FFT applied'
    !kernel(i,j): response at i of source at j
    !because dx = constant, only need to calculate i at first column
    allocate (k%k3%kernel(m%nw,m%nn))
    do i = 1,m%nw
      do j = 1,m%nn
        call compute_kernel(lambda,mu,m%x(j),m%y(j),m%z(j),  &
               m%dip(j),m%dx,m%dw((j-1)/m%nx+1),   &
               m%x(1+(i-1)*m%nx),m%y(1+(i-1)*m%nx),   &
               m%z(1+(i-1)*m%nx),m%dip(1+(i-1)*m%nx),IRET,tau)
        if (IRET == 0) then
          k%k3%kernel(i,j) = tau    
        else
          write(6,*) '!!WARNING!! : Kernel Singular, set value to 0,(i,j)',i,j
          k%k3%kernel(i,j) = 0d0
        end if
      end do
    end do
    do j = 1,m%nn
      write(99,*) k%k3%kernel(1,j)
    end do

  end select

  write(6,*) 'Kernel intialized'
  
end subroutine init_kernel   

!=========================================================
subroutine compute_stress(tau,K,v)

  type(kernel_type), intent(inout)  :: K
  double precision , intent(out) :: tau(:)
  double precision , intent(in) :: v(:)

  ! depends on dimension (0D, 1D or 2D fault)
  select case (K%kind)
    case(1); call compute_stress_1d(tau,K%k1,v)
    case(2); call compute_stress_2d(tau,K%k2f,v)
    case(3); call compute_stress_3d_fft(tau,K%k3f,v)
    case(4); call compute_stress_3d(tau,K%k3,v)
  end select

end subroutine compute_stress

!--------------------------------------------------------
subroutine compute_stress_1d(tau,k1,v)

  double precision , intent(out) :: tau(1)
  double precision , intent(in) :: k1,v(1)

  tau =  - k1*v

end subroutine compute_stress_1d

!--------------------------------------------------------
subroutine compute_stress_2d(tau,k2f,v)

  use fftsg, only : my_rdft
  
  type(kernel_2d_fft), intent(inout)  :: k2f
  double precision , intent(out) :: tau(:)
  double precision , intent(in) :: v(:)

  double precision :: tmp(k2f%nnfft)
  integer :: nn

  nn = size(v)
  tmp( 1 : nn ) = v
  tmp( nn+1 : k2f%nnfft ) = 0d0  
  call my_rdft(1,tmp,k2f%m_fft) 
  tmp = - k2f%kernel * tmp
  call my_rdft(-1,tmp,k2f%m_fft)
  tau = tmp(1:nn)

end subroutine compute_stress_2d

!--------------------------------------------------------
subroutine compute_stress_3d(tau,k3,v)

  type(kernel_3D), intent(in)  :: k3
  double precision , intent(out) :: tau(:)
  double precision , intent(in) :: v(:)

  integer :: nn,nw,nx,i,iw,ix,j,jw,jx,idx,jj

  nn = size(v)
  nw = size(k3%kernel,1)
  nx = nn/nw

   tau = 0d0
   i=0
   do iw=1,nw
   do ix=1,nx
     i = i+1
     j = 0
     do jw=1,nw
     do jx=1,nx
       j = j+1
       idx = abs(jx-ix)  ! note: abs(x) assumes some symmetries in the kernel
       jj = (jw-1)*nx + idx + 1 
       tau(i) = tau(i) - k3%kernel(iw,jj) * v(j)
     end do
     end do
   end do
   end do

end subroutine compute_stress_3d

!--------------------------------------------------------
! version with FFT along-strike
! Assumes kernel has been FFT'd during initialization
! Assumes storage with along-strike index running faster than along-dip
! Note: to avoid periodic wrap-around, fft convolution requires twice longer arrays
!       and zero-padding (pre-processing) and chop-in-half (post-processing)

subroutine compute_stress_3d_fft(tau,k3f,v)

  use fftsg, only : my_rdft

  type(kernel_3D_fft), intent(inout)  :: k3f
  double precision , intent(out) :: tau(:)
  double precision , intent(in) :: v(:)

  double precision :: tmpzk(k3f%nw,k3f%nxfft), tmp(k3f%nxfft)
  integer :: n,k

  do n = 1,k3f%nw
    tmp( 1 : k3f%nx ) = v( (n-1)*k3f%nx+1 : n*k3f%nx )
    tmp( k3f%nx+1 : k3f%nxfft ) = 0d0  ! convolution requires zero-padding
    call my_rdft(1,tmp,k3f%m_fft) 
    tmpzk(n,:) = tmp
  enddo

  ! convolution in Fourier domain is a product of complex numbers:
  ! K*V = (ReK + i*ImK)*(ReV+i*ImV) 
  !     = ReK*ReV - ImK*ImV  + i*( ReK*ImV + ImK*ReV )
  !
  ! wavenumber = 0, real
  tmpzk(:,1) = matmul( k3f%kernel(:,:,1), tmpzk(:,1) ) 
  ! wavenumber = Nyquist, real
  tmpzk(:,2) = matmul( k3f%kernel(:,:,2), tmpzk(:,2) ) 
  ! higher wavenumbers, complex
  do k = 3,k3f%nxfft-1,2
    ! real part = ReK*ReV - ImK*ImV
    tmpzk(:,k)  = matmul( k3f%kernel(:,:,k), tmpzk(:,k) )  &
                - matmul( k3f%kernel(:,:,k+1), tmpzk(:,k+1) )
    ! imaginary part = ReK*ImV + ImK*ReV
    tmpzk(:,k+1) = matmul( k3f%kernel(:,:,k), tmpzk(:,k+1) )  &
                 + matmul( k3f%kernel(:,:,k+1), tmpzk(:,k) )
!    tmpzk(:,k) = tmp
  enddo
  
  do n = 1,k3f%nw
    tmp = - tmpzk(n,:)
    call my_rdft(-1,tmp,k3f%m_fft)
    tau( (n-1)*k3f%nx+1 : n*k3f%nx ) = tmp(1:k3f%nx) ! take only first half of array
  enddo

end subroutine compute_stress_3d_fft

end module fault_stress