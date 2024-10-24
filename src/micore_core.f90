!
! MICO-RE
!   [Minimal Implementation of Cloud Optical Retrieval]
!
! micore_core.f90
!
! Author: Rintaro Okamura
!
! Description:
!   main routine and libraries of MICO-RE cloud optical retrieval code
!
! ChangeLog
!   20151127 : First Version
!   20160511 : Revise akima interpolation
!   20170109 : Replace Gauss-Newton method with Levenberg-Marquardt method
!


module micore_core
  implicit none
  private

  public :: R_, RD_, R4_, verbose_flag
  public :: get_cmd_args
  public :: micore_retrieval

  ! based on HPARX library
  integer, parameter :: R_  = selected_real_kind(13) ! default precision
  integer, parameter :: RD_ = selected_real_kind(13) ! higher  precision
  integer, parameter :: R4_ = selected_real_kind(6)  ! 4-byte real

  real(R_), parameter :: NAPIER = 2.7182818284590452353602874711352_R_
  real(R_), parameter :: ASYM_G = 0.86_R_ ! asymmetry factor

  ! flag for verbose mode
  logical, parameter :: verbose_flag = .true.

  ! threshold value for convergence of cost function
  real(R_), parameter :: threshold = 1e-13_R_
  real(R_), parameter :: diff_thre = 1e-13_R_
  ! max # of iteration
  integer, parameter :: max_iter = 9999
  ! max and min of tau and cder
  real(R_), parameter :: tau_max  = 150.0_R_
  real(R_), parameter :: tau_min  = 0.0_R_
  real(R_), parameter :: cder_max = 55.0_R_
  real(R_), parameter :: cder_min = 0.0_R_

contains
  ! get commandline arguments
  !   this code is based on HPARX library
  subroutine get_cmd_args(narg, argv, argmsg)
    integer, intent(inout)    :: narg
    character(*), intent(out) :: argv(:)
    character(*), intent(in)  :: argmsg
    integer :: nn, i

    nn = command_argument_count()

    if (nn < narg) then
      write (*,*) argmsg
      stop
    end if

    do i = 1, nn
      call get_command_argument(i, argv(i))
    end do

    narg = nn
  end subroutine get_cmd_args

  ! get location inside of grid
  !   this code is based on HPARX library
  subroutine grid_idx_loc(xg, x, ix, rat, mext)
    real(R_), intent(in)  :: xg(:) ! vector
    real(R_), intent(in)  :: x     ! a value
    integer,  intent(out) :: ix    ! found grid index (1 <= ix <= size(xg)-1)
    real(R_), intent(out) :: rat   ! location between xg(ix) and xg(ix+1)
    !// xg(ix) <= x < xg(ix+1) if xg is  increasing vector and xg(1) <= x < xg(nx)
    !// xg(ix) >= x > xg(ix+1) if xg is deccreasing vector and xg(1) >= x > xg(nx)
    integer,  intent(in), optional :: mext ! if 1, extraporation (rat will be < 0 or > 1)
    integer  :: i, iz

    ! Too few grid points
    iz = size(xg)
    if (iz <= 1) then
       ix = 1
       rat = 0.0_R_

       ! Increasing vector
    else if (xg(1) < xg(iz)) then
       if (x <= xg(1)) then ! out of lower limit
          ix = 1
          rat = 0.0_R_
          if (present(mext)) then
             if (mext == 1) rat = (x - xg(1)) / (xg(2) - xg(1))
          end if
       else if (x >= xg(iz)) then ! out of upper limit
          ix = iz - 1
          rat = 1.0_R_
          if (present(mext)) then
             if (mext == 1) rat = (x - xg(ix)) / (xg(iz) - xg(ix))
          end if
       else                ! in the grid
          ix = 1
          do
             if (iz <= ix + 1) exit
             i = (ix + iz) / 2
             if (x >= xg(i)) then
                ix = i
             else
                iz = i
             end if
          end do
          rat = (x - xg(ix)) / (xg(ix + 1) - xg(ix))
       end if

       ! Decreasing vector
    else
       if (x >= xg(1)) then ! out of lower limit
          ix = 1
          rat = 0.0_R_
          if (present(mext)) then
             if (mext == 1) rat = (x - xg(1)) / (xg(2) - xg(1))
          end if
       else if (x <= xg(iz)) then ! out of upper limit
          ix = iz - 1
          rat = 1.0_R_
          if (present(mext)) then
             if (mext == 1) rat = (x - xg(ix)) / (xg(iz) - xg(ix))
          end if
       else                ! in the grid
          ix = 1
          do
             if (iz <= ix + 1) exit
             i = (ix + iz) / 2
             if (x <= xg(i)) then
                ix = i
             else
                iz = i
             end if
          end do
          rat = (x - xg(ix)) / (xg(ix + 1) - xg(ix))
       end if
    end if
  end subroutine grid_idx_loc

  ! simple insert sort
  function insert_sort(dat)
    real(R_) :: dat(:)
    real(R_), allocatable :: insert_sort(:)
    real(R_) :: tmp
    integer  :: i, j

    do i = 2, size(dat)
      tmp = dat(i)
      if (dat(i-1) > tmp) then
        j = i
        do
          dat(j) = dat(j-1)
          j = j - 1
          if (j < 1 .or. dat(j-1) <= tmp) exit
        end do
        dat(j) = tmp
      end if
    end do

    allocate (insert_sort(size(dat)))
    insert_sort(:) = dat(:)
  end function insert_sort

  ! select unique elements from array
  function select_uniq_elems(dat)
    real(R_) :: dat(:)
    real(R_), allocatable :: select_uniq_elems(:)
    integer :: i, cnt

    dat(:) = insert_sort(dat(:))
    cnt = 1
    do i = 2, size(dat)
      if (dat(i-1) /= dat(i)) then
        cnt = cnt + 1
      end if
    end do
    allocate (select_uniq_elems(cnt))
    cnt = 1
    select_uniq_elems(1) = dat(1)
    do i = 2, size(dat)
      if (select_uniq_elems(cnt) /= dat(i)) then
        cnt = cnt + 1
        select_uniq_elems(cnt) = dat(i)
      end if
    end do
  end function select_uniq_elems

  ! akima interpolation with dxdy
  !   y = y0 + c1*x + c2*x^2 + c3*x^3
  !   this code is based on HPARX library
  subroutine akima_withK(xtab, ytab, x, y, k)
    real(R_), intent(in)  :: xtab(:)
    real(R_), intent(in)  :: ytab(:)
    real(R_), intent(in)  :: x
    real(R_), intent(out) :: y
    real(R_), intent(out) :: k
    real(R_) :: c1, c2, c3
    real(R_) :: dydxtab(0:1), d(-2:2), dx, dy, w0, w1, ax
    integer  :: nx, i, ix

    nx = size(ytab)

    call grid_idx_loc(xtab, x, ix, ax, 1)

    ! Trapezoidal difference
    if (ix >= 3 .and. ix <= nx - 3) then
       d(-2:2) = (ytab(ix-1:ix+3) - ytab(ix-2:ix+2)) / (xtab(ix-1:ix+3) - xtab(ix-2:ix+2))
    else if (ix <= 2) then
       if (ix == 2) then
          d(-1:2) = (ytab(ix  :ix+3) - ytab(ix-1:ix+2)) / (xtab(ix  :ix+3) - xtab(ix-1:ix+2))
          d(-2) = 2.0_R_ * d(-1) - d(0)
       else
          d(0:2)  = (ytab(ix+1:ix+3) - ytab(ix  :ix+2)) / (xtab(ix+1:ix+3) - xtab(ix  :ix+2))
          d(-1) = 2.0_R_ * d(0)  - d(1)
          d(-2) = 2.0_R_ * d(-1) - d(0)
       end if
    else
       if (ix == nx - 2) then
          d(-2:1) = (ytab(ix-1:ix+2) - ytab(ix-2:ix+1)) / (xtab(ix-1:ix+2) - xtab(ix-2:ix+1))
          d(2) = 2.0_R_ * d(1) - d(0)
       else !if (ix == nx - 1) then
          d(-2:0) = (ytab(ix-1:ix+1) - ytab(ix-2:ix  )) / (xtab(ix-1:ix+1) - xtab(ix-2:ix  ))
          d(1) = 2.0_R_ * d(0) - d(-1)  
          d(2) = 2.0_R_ * d(1) - d(0)
       end if
    end if

    ! Derivative estimates
    do i = 0, 1
       w1 = abs(d(i+1) - d(i  ))
       w0 = abs(d(i-1) - d(i-2))
       if (w1 + w0 == 0.0_R_) then
          dydxtab(i) = (d(i-1) + d(i)) * 0.5_R_
       else
          dydxtab(i) = (w1 * d(i-1) + w0 * d(i)) / (w1 + w0)
       end if
    end do

    dx = xtab(ix+1) - xtab(ix)
    dy = ytab(ix+1) - ytab(ix)
    c1 = dydxtab(0) * dx
    c2 = 3.0_R_ * dy - (c1 + dydxtab(1)*dx) - c1
    c3 = -2.0_R_ * dy + (c1 + dydxtab(1)*dx)
    y = ytab(ix) + ax * (c1 + ax * (c2 + ax * c3))
    k = (c1 + ax * (2.0_R_ * c2 + 3.0_R_ * c3 * ax)) / dx
  end subroutine akima_withK

  ! easy alias for akima_withK
  function akima_intp(xtab, ytab, x)
    real(R_) :: xtab(:)
    real(R_) :: ytab(:)
    real(R_) :: x
    real(R_) :: akima_intp
    real(R_) :: k

    call akima_withK(xtab, ytab, x, akima_intp, k)
  end function akima_intp

  ! calculate derivative of akima intp
  function akima_derv(p1, p2, p3, x1, x)
    real(R_) :: p1, p2, p3, x1, x
    real(R_) :: akima_derv

    akima_derv = &
      3.0_R_ * p3 * x**2 + &
      (2.0_R_ * p2 - 6.0_R_ * p3 * x1) * x - &
      2.0_R_ * p2 * x1 + 3.0_R_ * p3 * x1**2 + p1
  end function akima_derv

  ! separate look-up table into several vectors
  subroutine separate_lut(lut, lut_refs1, lut_refs2, tau_arr, cder_arr)
    real(R_), intent(in)  :: lut(:,:)
    real(R_), intent(out) :: lut_refs1(:), lut_refs2(:) ! reflectances of lut
    real(R_), intent(out) :: tau_arr(:), cder_arr(:)    ! tau and cder in lut
    integer :: i, lutsize

    lutsize = size(lut, 1)

    do i = 1, lutsize
      tau_arr(i)   = lut(i, 1)
      cder_arr(i)  = lut(i, 2)
      lut_refs1(i) = lut(i, 3)
      lut_refs2(i) = lut(i, 4)
    end do
  end subroutine separate_lut

  function nonlin_conv_tau(tau)
    real(R_) :: tau
    real(R_) :: nonlin_conv_tau

    nonlin_conv_tau = ((1 - ASYM_G) * tau) / (1 + (1 - ASYM_G) * tau)
  end function nonlin_conv_tau

  function nonlin_conv_cder(cder)
    real(R_) :: cder
    real(R_) :: nonlin_conv_cder

    nonlin_conv_cder = sqrt(cder)
  end function nonlin_conv_cder

  function inv_nonlin_conv_tau(ltau, dx)
    real(R_) :: ltau
    real(R_) :: dx
    real(R_) :: inv_nonlin_conv_tau

    inv_nonlin_conv_tau = (ltau + dx) / ((1 - ASYM_G) * (1 - (ltau + dx)))
  end function inv_nonlin_conv_tau

  function inv_nonlin_conv_cder(lcder, dx)
    real(R_) :: lcder
    real(R_) :: dx
    real(R_) :: inv_nonlin_conv_cder

    inv_nonlin_conv_cder = (lcder + dx) ** 2
  end function inv_nonlin_conv_cder

  ! 1D-linear algebra solver for limited case (only for 2x2-matrix)
  function solve_1Dlinalg_choles(A, b) result(x)
    real(R_) :: A(2,2)
    real(R_) :: b(2)
    real(R_) :: x(2)
    real(R_) :: L(2,2), z(2)

    L(1,1) = sqrt(A(1,1))
    L(1,2) = 0
    L(2,1) = A(1,2) / L(1,1)
    L(2,2) = sqrt(A(2,2) - L(2,1)**2)

    z(1) = b(1) / L(1,1)
    z(2) = (b(2) - L(2,1) * z(1)) / L(2,2)

    x(2) = z(2) / L(2,2)
    x(1) = (z(1) - L(2,1) * x(2)) / L(1,1)
  end function solve_1Dlinalg_choles

  ! estimate initial tau and cder by least square method
  function estimate_initial_values(lut_refs1, lut_refs2, tau_arr, cder_arr, obs_ref)
    real(R_) :: lut_refs1(:), lut_refs2(:) ! reflectances of lut
    real(R_) :: tau_arr(:), cder_arr(:)    ! tau and cder in lut
    real(R_) :: obs_ref(:)
    real(R_) :: estimate_initial_values(2)
    integer :: minind

    lut_refs1(:) = lut_refs1(:) / maxval(lut_refs1(:))
    lut_refs2(:) = lut_refs2(:) / maxval(lut_refs2(:))
    obs_ref(1) = obs_ref(1) / maxval(lut_refs1(:))
    obs_ref(2) = obs_ref(2) / maxval(lut_refs2(:))

    minind = minloc((lut_refs1 - obs_ref(1))**2 + (lut_refs2 - obs_ref(2))**2, 1)

    estimate_initial_values(1) = tau_arr(minind)
    estimate_initial_values(2) = cder_arr(minind)
  end function estimate_initial_values

  ! estimate reflectances from cloud properties by using look-up table
  subroutine estimate_refs(lut_refs1, lut_refs2, tau_arr, cder_arr, tau, cder, est_refs, k)
    real(R_), intent(in)  :: lut_refs1(:), lut_refs2(:) ! reflectances of lut
    real(R_), intent(in)  :: tau_arr(:), cder_arr(:)    ! tau and cder in lut
    real(R_), intent(in)  :: tau, cder
    real(R_), intent(out) :: est_refs(2)
    real(R_), intent(out) :: k(2,2) ! Jacobian matrix
    real(R_), allocatable :: unq_tau(:), unq_cder(:) ! unique tau and cder
    real(R_) :: intp_tau(5), intp_cder(5)
    real(R_) :: tmp_ref1(5), tmp_ref2(5)
    real(R_) :: tmp_ref(5,2)
    integer  :: itau, icder
    real(R_) :: ltau, lcder
    real(R_) :: rat
    integer  :: i, j

    ltau  = nonlin_conv_tau(tau)
    lcder = nonlin_conv_cder(cder)

    ! extract unique values
    allocate (unq_tau(size(select_uniq_elems(tau_arr))))
    allocate (unq_cder(size(select_uniq_elems(cder_arr))))
    unq_tau(:)  = select_uniq_elems(tau_arr(:))
    unq_cder(:) = select_uniq_elems(cder_arr(:))

    call grid_idx_loc(unq_tau, tau, itau, rat)
    if (itau <= 2 .and. itau > size(unq_tau) - 2) then
      write(*,*), 'Too few points in this LUT.'
      stop
    else if (itau <= 2) then
      itau = 3
    else if (itau > size(unq_tau) - 2) then
      itau = size(unq_tau) - 2
    else if (itau > size(unq_tau) - 1) then
      itau = size(unq_tau) - 1
    end if
    intp_tau(1) = nonlin_conv_tau(unq_tau(itau-2))
    intp_tau(2) = nonlin_conv_tau(unq_tau(itau-1))
    intp_tau(3) = nonlin_conv_tau(unq_tau(itau))
    intp_tau(4) = nonlin_conv_tau(unq_tau(itau+1))
    intp_tau(5) = nonlin_conv_tau(unq_tau(itau+2))

    call grid_idx_loc(unq_cder, cder, icder, rat)
    if (icder <= 2 .and. icder > size(unq_cder) - 2) then
      write(*,*), 'Too few points in this LUT.'
      stop
    else if (icder <= 2) then
      icder = 3
    else if (icder > size(unq_cder) - 2) then
      icder = size(unq_cder) - 2
    else if (icder > size(unq_cder) - 1) then
      icder = size(unq_cder) - 1
    end if
    intp_cder(1) = nonlin_conv_cder(unq_cder(icder-2))
    intp_cder(2) = nonlin_conv_cder(unq_cder(icder-1))
    intp_cder(3) = nonlin_conv_cder(unq_cder(icder))
    intp_cder(4) = nonlin_conv_cder(unq_cder(icder+1))
    intp_cder(5) = nonlin_conv_cder(unq_cder(icder+2))

    ! interpolation with CDER
    do i = 1, 5
      do j = 1, 5
        tmp_ref1(j) = lut_refs1(size(unq_cder) * (itau+i-4) + (icder+j-3))
        tmp_ref2(j) = lut_refs2(size(unq_cder) * (itau+i-4) + (icder+j-3))
      end do
      tmp_ref(i,1) = akima_intp(intp_cder, tmp_ref1, lcder)
      tmp_ref(i,2) = akima_intp(intp_cder, tmp_ref2, lcder)
    end do

    ! interpolation with TAU
    call akima_withK(intp_tau, tmp_ref(:,1), ltau, est_refs(1), k(1,1))
    call akima_withK(intp_tau, tmp_ref(:,2), ltau, est_refs(2), k(2,1))

    ! interpolation with TAU
    do i = 1, 5
      do j = 1, 5
        tmp_ref1(j) = lut_refs1(size(unq_cder) * (itau+j-4) + (icder+i-3))
        tmp_ref2(j) = lut_refs2(size(unq_cder) * (itau+j-4) + (icder+i-3))
      end do
      tmp_ref(i,1) = akima_intp(intp_tau, tmp_ref1, ltau)
      tmp_ref(i,2) = akima_intp(intp_tau, tmp_ref2, ltau)
    end do

    ! interpolation with CDER
    ! tmp_ref1 is for dummy
    call akima_withK(intp_cder, tmp_ref(:,1), lcder, tmp_ref1(1), k(1,2))
    call akima_withK(intp_cder, tmp_ref(:,2), lcder, tmp_ref1(2), k(2,2))

    ! mean value of two different order of interpolations
    est_refs(1) = (est_refs(1) + tmp_ref1(1)) / 2
    est_refs(2) = (est_refs(2) + tmp_ref1(2)) / 2

    deallocate (unq_tau, unq_cder)
  end subroutine estimate_refs

  ! cost function J
  !   J = (R_obs1 - R_est1 R_obs2 - R_est2) S_e (R_obs1 - R_est1 R_obs2 - R_est2)
  function cost_func(obs_ref, est_ref, s)
    real(R_) :: obs_ref(:)
    real(R_) :: est_ref(:)
    real(R_) :: s(2,2) ! inverse of error covariance matrix
    real(R_) :: refdiff_vec(2) ! difference vector of reflectances
    real(R_) :: cost_func

    refdiff_vec(:) = obs_ref(:) - est_ref(:)

    cost_func = dot_product(matmul(refdiff_vec(:), s(:,:)), refdiff_vec(:))
  end function cost_func

  ! update cloud properties
  function update_cloud_properties(obs_ref, est_ref, cps, k, s, gam)
    real(R_) :: obs_ref(2), est_ref(2)
    real(R_) :: cps(2)
    real(R_) :: update_cloud_properties(2)
    real(R_) :: k(2,2) ! Jacobian matrix
    real(R_) :: s(2,2) ! inverse of error covariance matrix
    real(R_) :: dx(2)
    real(R_) :: refdiff_vec(2) ! difference vector of reflectances
    real(R_) :: e(2,2) = reshape((/1,0,0,1/), (/2,2/))
    real(R_) :: gam

    refdiff_vec(:) = obs_ref(:) - est_ref(:)

    dx(:) = solve_1Dlinalg_choles(matmul(matmul(transpose(k(:,:)), s(:,:)), k(:,:)) + e(:,:) * gam, &
      matmul(matmul(transpose(k(:,:)), s(:,:)), refdiff_vec(:)))

    update_cloud_properties(1) = inv_nonlin_conv_tau(nonlin_conv_tau(cps(1)), dx(1))
    update_cloud_properties(2) = inv_nonlin_conv_cder(nonlin_conv_cder(cps(2)), dx(2))

    update_cloud_properties(1) = max(tau_min,  min(tau_max,  update_cloud_properties(1)))
    update_cloud_properties(2) = max(cder_min, min(cder_max, update_cloud_properties(2)))
  end function update_cloud_properties

  ! main routine of retrieval code
  !   input:
  !     lut: look-up table (tau, cder -> ref1, ref2)
  !       (i, 1): tau  (Cloud Optical Thickness)
  !       (i, 2): cder (Cloud Droplet Effective Radius)
  !       (i, 3): reflectance1
  !       (i, 4): reflectance2
  !     obs_ref: array of observed reflectances
  !   output:
  !     tau: estimated cloud optical thickness
  !     cder: estimated cloud droplet effective radius
  subroutine micore_retrieval(lut, obs_ref, tau, cder, cost_res)
    real(R_), intent(in)  :: lut(:,:)
    real(R_), intent(in)  :: obs_ref(:)
    real(R_), intent(out) :: tau, cder
    real(R_), intent(out) :: cost_res
    real(R_) :: lut_refs1(size(lut, 1)), lut_refs2(size(lut, 1)) ! reflectances of lut
    real(R_) :: tau_arr(size(lut,1)), cder_arr(size(lut, 1)) ! tau and cder in lut
    real(R_) :: est_ref(2) ! estimated reflectances
    real(R_) :: cps(2) ! cloud physical parameters
    real(R_) :: k(2,2) ! an array of akima coefficients
    real(R_) :: s(2,2) ! inverse of error covariance matrix
    real(R_) :: e(2,2) = reshape((/1,0,0,1/), (/2,2/))
    real(R_) :: prev_cost = 100.0_R_
    real(R_) :: best_cost = 100.0_R_
    real(R_) :: gam = 0.01_R_ ! fudge factor
    integer  :: cost_diff_count = 0
    integer  :: cost_diff_count_inv = 0
    real(R_) :: best_cps(2) = (/0.0_R_, 0.0_R_/)
    integer  :: i

    ! initialization
    call separate_lut(lut, lut_refs1, lut_refs2, tau_arr, cder_arr)
    cps = estimate_initial_values(lut_refs1, lut_refs2, tau_arr, cder_arr, obs_ref)

    ! temporarily, error covariance matrix is unit.
    s(:,:) = e(:,:)

    ! main loop of optimal estimation
    do i = 1, max_iter
      if (verbose_flag) write (*,*) "# iterate step: ", i

      if (verbose_flag) then
        write (*,*) "# estimated TAU:  ", cps(1)
        write (*,*) "# estimated CDER: ", cps(2)
      end if

      call estimate_refs(lut_refs1, lut_refs2, tau_arr, cder_arr, cps(1), cps(2), est_ref, k(:,:))
      if (verbose_flag) then
        write (*,*) "# observed  REF1: ", obs_ref(1)
        write (*,*) "# observed  REF2: ", obs_ref(2)
        write (*,*) "# estimated REF1: ", est_ref(1)
        write (*,*) "# estimated REF2: ", est_ref(2)
      end if

      cost_res = cost_func(obs_ref, est_ref, s(:,:))
      if (verbose_flag) then
        write (*,*) "# COST: ", cost_res
      end if
      if (cost_res < threshold) exit
      if (prev_cost - cost_res >= 0) then
        if (prev_cost - cost_res < diff_thre) then
          if (cost_diff_count >= 3) then
            exit
          else
            cost_diff_count = cost_diff_count + 1
          end if
        else
          cost_diff_count = 0
          cost_diff_count_inv = 0
        end if
        gam = gam * 0.1_R_

        if (cost_res < best_cost) then
          best_cost = cost_res
          best_cps(:) = cps(:)
        endif

        cps = update_cloud_properties(obs_ref, est_ref, cps, k(:,:), s(:,:), gam)
      else
        if (prev_cost - cost_res < diff_thre) then
          if (cost_diff_count_inv >= 3) then
            exit
          else
            cost_diff_count_inv = cost_diff_count_inv + 1
          end if
        else
          cost_diff_count = 0
          cost_diff_count_inv = 0
        end if
        gam = gam * 10.0_R_
      end if

      prev_cost = cost_res
    end do

    if (cost_res < best_cost) then
      best_cps(:) = cps(:)
    else
      cost_res = best_cost
    endif

    tau  = best_cps(1)
    cder = best_cps(2)

  end subroutine micore_retrieval
end module micore_core
