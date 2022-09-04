;+
;
; NAME:
;   stx_em
;
; PURPOSE:
;   This function implements the count-based Expectation Maximization 
;   algorithm (see Massa, P., et al., "Count-based imaging model for the Spectrometer/Telescope for
;   Imaging X-rays (STIX) in Solar Orbiter", 2019).
;
; INPUTS:
;   pixel_data_summed: type="stx_pixel_data_summed"
;                      pixel data structure containing photon counts per time, energy, detector, and pixel
;                      (the counts registered are summed as if they were recorded by 4 virtual pixels per
;                      detector). For details on the summation see the header of 'stx_pixel_data_sum.pro'.
; KEYWORDS:
;   DET_USED: array containing the indices of detector used 
;             (default is 0-31, 8 and 9 excluded)
;   IMSIZE: output map size in pixels (default is [129, 129])
;   PIXEL: pixel size in arcsec (default is [1., 1.])
;   MAXITER: max number of iterations (default is 5000)
;   TOLERANCE: parameter for the stopping rule (default is 0.01)
;   SILENT: if not set, plots the STD (variable to test convergence) and the
;           C-statistic every 25 iterations
;   MAKEMAP: if set, returns the map structure. Otherwise returns the 2D matrix
;   XYOFFSET: array containing the map center coordinates.
;
; RETURNS:
;   an image (2D matrix) or an image map in the structure format provided by the
;   routine make_map.pro
;
; HISTORY: January 2018, Duval-Poo, M. A., Benvenuto F. created
;          January 2019, Massa P., modified taking into account 
;             -the time range of the measurements 
;             -the xyoffset 
;             -the detector used
;             -the summation of the counts recorded by the pixels.
;          June 2022, Massa P., 'aux_data' added
;          August 2022, Massa P., made it compatible with the up-to-date imaging software and added backrgound correction
;                       in the EM iterative scheme
;             
;CONTACT: massa.p@dima.unige.it

FUNCTION stx_em, pixel_data_summed, aux_data, imsize=imsize, pixel=pixel, $
                 mapcenter=mapcenter, subc_index=subc_index, $
                 maxiter=maxiter, tolerance=tolerance, silent=silent, makemap=makemap

default, subc_index, stix_label2ind(['3a','3b','3c','4a','4b','4c','5a','5b','5c','6a','6b','6c',$
                                       '7a','7b','7c','8a','8b','8c','9a','9b','9c','10a','10b','10c'])

default, maxiter, 5000
default, imsize, [129, 129]
default, pixel, [1., 1.]
default, tolerance, 0.001
default, silent, 0
default, makemap, 0
default, mapcenter, [0, 0]


; input parameters control
if imsize[0] ne imsize[1] then message, 'Error: imsize must be square.'
if pixel[0] ne pixel[1] then message, 'Error: pixel size per dimension must be equal.'

;;***************** Phase calibration factors

;; Grid phase correction
tmp = read_csv(loc_file( 'GridCorrection.csv', path = getenv('STX_VIS_DEMO') ), header=header, table_header=tableheader, n_table_header=2 )
grid_phase_corr = tmp.field2[subc_index]

;; "Ad hoc" phase correction (for removing residual errors)
tmp = read_csv(loc_file( 'PhaseCorrFactors.csv', path = getenv('STX_VIS_DEMO')), header=header, table_header=tableheader, n_table_header=3 )
ad_hoc_phase_corr = tmp.field2[subc_index]

; Sum over top and bottom pixels
sumcase = pixel_data_summed.SUMCASE
case sumcase of

  'TOP':     begin
    phase_factor = 46.1
    pixel_ind = [0]
  end

  'BOT':     begin
    phase_factor = 46.1
    pixel_ind = [1]
  end

  'TOP+BOT': begin
    phase_factor = 46.1
    pixel_ind = [0,1]
  end

  'ALL': begin
    phase_factor = 45.0
    pixel_ind = [0,1,2]
  end

  'SMALL': begin
    phase_factor = 22.5
    pixel_ind = [2]
  end
end

phase_corr = grid_phase_corr + ad_hoc_phase_corr + phase_factor
phase_corr *= !dtor

;;**************** Giordano's (u,v) points

subc_str = stx_construct_subcollimator()

uv = stx_uv_points_giordano()
u = -uv.u * subc_str.phase
v = -uv.v * subc_str.phase
u = u[subc_index]
v = v[subc_index]

;;**************** Transmission matrix

; Creation of the matrix 'H' used in the EM algorithm
H = stx_map2pixelabcd_matrix(imsize, pixel, u, v, phase_corr, xyoffset = mapcenter, SUMCASE = sumcase)

; Vectorization of the matrix 'pixel_data.counts' containing the number of counts recorded
; by STIX pixels
n_det_used = n_elements(subc_index)
countrates = pixel_data_summed.COUNT_RATES[subc_index,*]
y = reform(countrates, n_det_used*4)

countrates_bkg = pixel_data_summed.COUNT_RATES_ERROR_BKG[subc_index,*]
b = reform(countrates_bkg, n_det_used*4)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; EXPECTATION MAXIMIZATION ALGORITHM

;Initialization
x = fltarr((size(H,/dim))[1]) + 1.
y_index = where(y gt 0.)
Ht1 = H ## (y*0.0+1.0)
H2 = H^2

if ~keyword_set(silent) then print, 'EM iterations: ' & print, 'N. Iter:      STD:          C-STAT:'

; Loop of the algorithm
for iter = 1, maxiter do begin
  Hx = H # x
  z = f_div(y , Hx + b)
  Hz = H ## z

  x = x * transpose(f_div(Hz, Ht1))

  cstat = 2. / n_elements(y[y_index]) * total(y[y_index] * alog(f_div(y[y_index],Hx[y_index])) + Hx[y_index] - y[y_index])

  ; Stopping rule
  if iter gt 10 and (iter mod 25) eq 0 then begin
    emp_back_res = total((x * (Ht1 - Hz))^2)
    std_back_res = total(x^2 * (f_div(1.0, Hx) # H2))
    std_index = f_div(emp_back_res, std_back_res)

    if ~keyword_set(silent) then print, iter, std_index, cstat

    if std_index lt tolerance then break

  endif
endfor

x_im = reform(x, imsize[0],imsize[1])

;;;;;;;;;;;; After

em_map = make_map(x_im)
this_estring=strtrim(fix(pixel_data_summed.ENERGY_RANGE[0]),2)+'-'+strtrim(fix(pixel_data_summed.ENERGY_RANGE[1]),2)+' keV'
em_map.ID = 'STIX EM '+this_estring+': '
em_map.dx = pixel[0]
em_map.dy = pixel[1]

time_range = stx_time2any(pixel_data_summed.TIME_RANGE)
em_map.time = anytim((time_range[0]+time_range[1])/2.,/vms)

em_map.DUR = anytim(time_range[1])-anytim(time_range[0])

;rotate map to heliocentric view
em__map=em_map
em__map.data=rotate(em_map.data,1)

; Compute the mapcenter
this_mapcenter = stx_rtn2stx_coord(mapcenter, aux_data, /inverse)
em__map.xc = this_mapcenter[0]
em__map.yc = this_mapcenter[1]

em__map=rot_map(em__map,-aux_data.ROLL_ANGLE,rcenter=[0.,0.])
em__map.ROLL_ANGLE = 0.
add_prop,em__map,rsun = aux_data.RSUN
add_prop,em__map,B0   = aux_data.B0
add_prop,em__map,L0   = aux_data.L0

return,em__map

end