function [emg_out, diag] = emg_reprocess_frontend(phi_electrodes_raw, phi_ground, cfg)
%EMG_REPROCESS_FRONTEND  Пересчёт ЭМГ из сырых потенциалов
%
% Повторяет фронтенд-тракт из emg_simulation_core:
%   1) Контактный импеданс (каузальный RC-фильтр, с дисбалансом)
%   2) Инструментальный усилитель (дифференциальное усиление + CMRR + дисбаланс)
%   3) Аналоговые фильтры (HP/LP/Notch)
%   4) Децимация (fs_internal → fs_output)
%   5) Шум измерения
%
% ВХОД:
%   phi_electrodes_raw{ea} : [n_elec x N] сырые потенциалы (В)
%   phi_ground{ea}         : [1 x N] потенциал земли (В)
%   cfg                    : полная конфигурация (с electrode_arrays)
%
% ВЫХОД:
%   emg_out{ea}  : [n_ch x M] обработанный ЭМГ (В), M = N/decimation
%   diag         : структура диагностики (CMRR_eff, утечки и т.д.)
%
% Использование:
%   [emg, diag] = emg_reprocess_frontend(R.phi_electrodes_raw, R.phi_ground, R.config);

    if nargin < 3, error('Usage: emg_reprocess_frontend(phi_raw, phi_gnd, cfg)'); end

    fs_int = cfg.simulation.fs_internal;
    fs_out = cfg.simulation.fs_output;
    decimation_factor = round(fs_int / fs_out);
    n_arrays = numel(cfg.electrode_arrays);

    emg_out = cell(n_arrays, 1);
    diag = struct();
    diag.arrays = cell(n_arrays, 1);

    for ea = 1:n_arrays
        ea_cfg = cfg.electrode_arrays{ea};

        % Гарантируем наличие всех полей
        ea_cfg = ensure_defaults(ea_cfg);

        phi_e = phi_electrodes_raw{ea};
        phi_g = phi_ground{ea};
        if isempty(phi_e), emg_out{ea} = []; continue; end

        ad = struct();  % array diagnostics

        % === 1. Контактный импеданс ===
        [v_electrodes, v_gnd, ad.contact] = contact_impedance(phi_e, phi_g, fs_int, ea_cfg);

        % === 2. Инструментальный усилитель ===
        [emg_amp, ad.amplifier] = instrumentation_amplifier(v_electrodes, v_gnd, ea_cfg);

        % === 3. Аналоговые фильтры ===
        emg_filt = analog_filters(emg_amp, fs_int, ea_cfg);

        % === 4. Децимация ===
        n_ch = size(emg_filt, 1);
        N_out = ceil(size(emg_filt, 2) / decimation_factor);
        emg_dec = zeros(n_ch, N_out);
        for ch = 1:n_ch
            emg_dec(ch, :) = decimate(emg_filt(ch, :), decimation_factor);
        end

        % === 5. Шум измерения ===
        noise_density = ea_cfg.amplifier.noise_density;
        noise_power = noise_density * sqrt(fs_out);
        emg_out{ea} = emg_dec + noise_power * randn(size(emg_dec));

        diag.arrays{ea} = ad;
    end
end

%% ========================= Контактный импеданс ==========================
% Модель Рандлса + делитель Z_in:
%   Z_contact = Rs + Rc/(1+sRcCc)
%   H(s) = Z_in·(1+sτ) / ((Rs+Rc+Z_in) + sτ·(Rs+Z_in))
%   DC:  H = Z_in/(Rs+Rc+Z_in)
%   HF:  H = Z_in/(Rs+Z_in)  — Rs не шунтируется ёмкостью!
function [v_e, v_gnd, info] = contact_impedance(phi_e, phi_gnd, fs, ea_cfg)
    n_elec = size(phi_e, 1);
    N = size(phi_e, 2);

    Rs_base = getf_rp(ea_cfg.contact, 'Rs', 0);
    Rc_base = ea_cfg.contact.Rc;
    Cc_base = ea_cfg.contact.Cc;

    if isfield(ea_cfg, 'amplifier') && isfield(ea_cfg.amplifier, 'input_impedance') ...
            && ea_cfg.amplifier.input_impedance > 0
        Z_in = ea_cfg.amplifier.input_impedance;
    else
        Z_in = 200e6;
    end

    imb_on = isfield(ea_cfg, 'contact_imbalance') && ea_cfg.contact_imbalance.enabled;

    info = struct();
    info.imbalance_on = imb_on;
    info.fc = zeros(n_elec, 1);
    info.dc_gain = zeros(n_elec, 1);
    info.hf_gain = zeros(n_elec, 1);
    info.Z_in = Z_in;

    tau_max = Rc_base * Cc_base;
    if imb_on
        for ch = 1:min(n_elec, numel(ea_cfg.contact_imbalance.Rc_factors))
            Rc_f = ea_cfg.contact_imbalance.Rc_factors(ch);
            Cc_f = ea_cfg.contact_imbalance.Cc_factors(ch);
            tau_max = max(tau_max, Rc_base * Rc_f * Cc_base * Cc_f);
        end
        % Also account for ground electrode contact time constant (if present)
        Rc_g0 = Rc_base; Cc_g0 = Cc_base;
        if isfield(ea_cfg,'ground_electrode')
            ge = ea_cfg.ground_electrode;
            if isfield(ge,'Rc') && ~isempty(ge.Rc) && ge.Rc>0, Rc_g0 = ge.Rc; end
            if isfield(ge,'Cc') && ~isempty(ge.Cc) && ge.Cc>0, Cc_g0 = ge.Cc; end
        end
        if isfield(ea_cfg.contact_imbalance,'Rc_ground_factor') && isfield(ea_cfg.contact_imbalance,'Cc_ground_factor')
            tau_g = Rc_g0 * ea_cfg.contact_imbalance.Rc_ground_factor * Cc_g0 * ea_cfg.contact_imbalance.Cc_ground_factor;
            tau_max = max(tau_max, tau_g);
        end
    end
    n_warmup = min(round(5 * tau_max * fs), N);

    v_e = zeros(n_elec, N);
    c_blt = 2 * fs;

    for ch = 1:n_elec
        if imb_on && ch <= numel(ea_cfg.contact_imbalance.Rc_factors)
            Rc_ch = Rc_base * ea_cfg.contact_imbalance.Rc_factors(ch);
            Cc_ch = Cc_base * ea_cfg.contact_imbalance.Cc_factors(ch);
            if isfield(ea_cfg.contact_imbalance, 'Rs_factors') ...
                    && ch <= numel(ea_cfg.contact_imbalance.Rs_factors)
                Rs_ch = Rs_base * ea_cfg.contact_imbalance.Rs_factors(ch);
            else
                Rs_ch = Rs_base;
            end
        else
            Rc_ch = Rc_base; Cc_ch = Cc_base; Rs_ch = Rs_base;
        end

        tau = Rc_ch * Cc_ch;
        info.fc(ch) = 1 / (2*pi*tau);
        info.dc_gain(ch) = Z_in / (Rs_ch + Rc_ch + Z_in);
        info.hf_gain(ch) = Z_in / (Rs_ch + Z_in);

        % H(s) = Z_in(1+sτ)/((Rs+Rc+Z_in)+sτ(Rs+Z_in))
        b1 = Z_in * tau;          b0 = Z_in;
        a1 = tau * (Rs_ch + Z_in); a0 = Rs_ch + Rc_ch + Z_in;

        B = [b1*c_blt + b0, -b1*c_blt + b0];
        A = [a1*c_blt + a0, -a1*c_blt + a0];
        B = B / A(1);  A = A / A(1);

        x_ch = phi_e(ch, :);
        warmup = x_ch(1) * ones(1, n_warmup);
        x_padded = [warmup, x_ch];
        y_padded = filter(B, A, x_padded);
        v_e(ch, :) = y_padded(n_warmup+1 : end);
    end

    % --- Ground electrode / reference node through its own contact path ---
    if nargin < 2 || isempty(phi_gnd)
        v_gnd = zeros(1, N);
    else
        % ground factors (default = 1) if imbalance enabled
        Rc_gf = 1; Cc_gf = 1; Rs_gf = 1;
        if imb_on && isfield(ea_cfg.contact_imbalance, 'Rc_ground_factor')
            Rc_gf = ea_cfg.contact_imbalance.Rc_ground_factor;
        end
        if imb_on && isfield(ea_cfg.contact_imbalance, 'Cc_ground_factor')
            Cc_gf = ea_cfg.contact_imbalance.Cc_ground_factor;
        end
        if imb_on && isfield(ea_cfg.contact_imbalance, 'Rs_ground_factor')
            Rs_gf = ea_cfg.contact_imbalance.Rs_ground_factor;
        end

        % Base parameters for ground electrode contact path:
        % - Prefer explicit ea_cfg.ground_electrode.(Rc,Cc,Rs) if present
        % - Otherwise fall back to the main electrode contact (legacy)
        Rs_g0 = Rs_base;
        Rc_g0 = Rc_base;
        Cc_g0 = Cc_base;
        if isfield(ea_cfg, 'ground_electrode')
            ge = ea_cfg.ground_electrode;
            if isfield(ge,'Rs') && ~isempty(ge.Rs) && ge.Rs >= 0, Rs_g0 = ge.Rs; end
            if isfield(ge,'Rc') && ~isempty(ge.Rc) && ge.Rc > 0, Rc_g0 = ge.Rc; end
            if isfield(ge,'Cc') && ~isempty(ge.Cc) && ge.Cc > 0, Cc_g0 = ge.Cc; end
        end
        Rs_g = Rs_g0 * Rs_gf;
        Rc_g = Rc_g0 * Rc_gf;
        Cc_g = Cc_g0 * Cc_gf;
        b1 = tau_max; %#ok<NASGU> 
        % Use same bilinear form as channels, but with its own tau:
        tau_g = Rc_g * Cc_g;
        b1 = tau_g; b0 = 1;
        a1 = tau_g * (Rs_g + Z_in); a0 = Rs_g + Rc_g + Z_in;

        B = [b1*c_blt + b0, -b1*c_blt + b0];
        A = [a1*c_blt + a0, -a1*c_blt + a0];
        B = B / A(1);  A = A / A(1);

        x_g = phi_gnd(:).';
        warmup = x_g(1) * ones(1, n_warmup);
        x_padded = [warmup, x_g];
        y_padded = filter(B, A, x_padded);
        v_gnd = y_padded(n_warmup+1 : end);
    end

end

function v = getf_rp(S, f, def)
    if isfield(S, f), v = S.(f); else, v = def; end
end

%% ===================== Инструментальный усилитель ========================
% INA: v_out = G·(V_diff + α_eff·V_cm)
% α_eff = α_amp + ΔZ_source/(2·Z_cm_in)
% Two CM→DM mechanisms sum:
%   1) α_amp = 10^(-CMRR/20) — intrinsic INA leakage
%   2) α_imb = ΔZ/(2·Z_cm_in) — CMRR degradation from contact mismatch
function [y, info] = instrumentation_amplifier(v_e, v_gnd, ea_cfg)
    if isempty(v_e), y = v_e; info = struct(); return; end

    amp = ea_cfg.amplifier;
    G = amp.gain;
    if nargin < 2 || isempty(v_gnd), v_gnd = zeros(1, size(v_e,2)); end
    alpha_amp = 10^(-amp.cmrr_db / 20);

    % Входное синфазное сопротивление
    if isfield(amp, 'input_impedance') && amp.input_impedance > 0
        Z_cm_in = amp.input_impedance;
    else
        Z_cm_in = 200e6;
    end

    % Деградация CMRR от дисбаланса контакта
    alpha_imb = 0;
    if isfield(ea_cfg, 'contact_imbalance') && ea_cfg.contact_imbalance.enabled
        if isfield(ea_cfg, 'contact')
            Rc_base = ea_cfg.contact.Rc;
            Cc_base = ea_cfg.contact.Cc;
        else
            Rc_base = 100e3; Cc_base = 100e-9;
        end
        imb = ea_cfg.contact_imbalance;
        if numel(imb.Rc_factors) >= 3
            omega = 2*pi*50;
            Rc1 = Rc_base * imb.Rc_factors(1);
            Rc3 = Rc_base * imb.Rc_factors(3);
            Cc1 = Cc_base * imb.Cc_factors(1);
            Cc3 = Cc_base * imb.Cc_factors(min(3,end));
            Z1 = Rc1 / (1 + 1i*omega*Rc1*Cc1);
            Z3 = Rc3 / (1 + 1i*omega*Rc3*Cc3);
            dZ = abs(Z1 - Z3);
            alpha_imb = dZ / (2 * Z_cm_in);
        end
    end

    alpha = alpha_amp + alpha_imb;

    info = struct();
    info.gain = G;
    info.alpha_amp = alpha_amp;
    info.alpha_imb = alpha_imb;
    info.alpha_total = alpha;
    info.cmrr_db = amp.cmrr_db;
    info.cmrr_eff_db = -20*log10(max(alpha, eps));
    info.Z_cm_in = Z_cm_in;

    if isfield(ea_cfg, 'differential_pairs') && ~isempty(ea_cfg.differential_pairs)
        n_pairs = size(ea_cfg.differential_pairs, 1);
        y = zeros(n_pairs, size(v_e, 2));
        for p = 1:n_pairs
            ip = ea_cfg.differential_pairs(p, 1);
            im = ea_cfg.differential_pairs(p, 2);
            Vdiff = v_e(ip, :) - v_e(im, :);
            Vcm = (v_e(ip, :) + v_e(im, :)) / 2;
            % Reference for common-mode:
            % - If an explicit ground electrode trace is provided, reference CM to it.
            % - Otherwise (legacy), reference to the configured reference electrode inside v_e.
            if ~isempty(v_gnd)
                Vcm = Vcm - v_gnd;
            elseif isfield(ea_cfg, 'reference_electrode') && ea_cfg.reference_electrode > 0
                Vcm = Vcm - v_e(ea_cfg.reference_electrode, :);
            end
y(p, :) = G * (Vdiff + alpha * Vcm);
        end
    elseif size(v_e, 1) < 2
        y = G * v_e;
    else
        Vdiff = v_e(1, :) - v_e(end, :);
        Vcm   = (v_e(1, :) + v_e(end, :)) / 2 - v_gnd;
        y = G * (Vdiff + alpha * Vcm);
    end
end

%% ========================= Аналоговые фильтры ===========================
function emg = analog_filters(emg_amp, fs, ea_cfg)
    amp = ea_cfg.amplifier;

    [b_hp, a_hp] = butter(2, amp.highpass_cutoff/(fs/2), 'high');
    emg = filtfilt(b_hp, a_hp, emg_amp')';

    [b_lp, a_lp] = butter(4, amp.lowpass_cutoff/(fs/2), 'low');
    emg = filtfilt(b_lp, a_lp, emg')';

    if amp.notch_freq > 0 && amp.notch_bw > 0
        [b_n, a_n] = iirnotch(amp.notch_freq/(fs/2), amp.notch_bw/(fs/2));
        emg = filtfilt(b_n, a_n, emg')';
    end
end

%% =========================== Дефолты ====================================
function ea = ensure_defaults(ea)
    if ~isfield(ea, 'contact')
        ea.contact.Rs = 200;
        ea.contact.Rc = 100e3;
        ea.contact.Cc = 100e-9;
    end
    if ~isfield(ea.contact, 'Rs'), ea.contact.Rs = 200; end
    if ~isfield(ea, 'amplifier')
        ea.amplifier = struct();
    end
    a = ea.amplifier;
    if ~isfield(a, 'gain'),             a.gain = 1000; end
    if ~isfield(a, 'cmrr_db'),          a.cmrr_db = 90; end
    if ~isfield(a, 'noise_density'),     a.noise_density = 5e-9; end
    if ~isfield(a, 'input_impedance'),   a.input_impedance = 200e6; end
    if ~isfield(a, 'highpass_cutoff'),   a.highpass_cutoff = 20; end
    if ~isfield(a, 'lowpass_cutoff'),    a.lowpass_cutoff = 450; end
    if ~isfield(a, 'notch_freq'),        a.notch_freq = 50; end
    if ~isfield(a, 'notch_bw'),          a.notch_bw = 2; end
    ea.amplifier = a;

    if ~isfield(ea, 'differential_pairs'), ea.differential_pairs = [1, 3]; end
    if ~isfield(ea, 'reference_electrode'), ea.reference_electrode = 2; end

    if ~isfield(ea, 'contact_imbalance')
        ea.contact_imbalance.enabled = false;
        ea.contact_imbalance.Rc_factors = [1 1 1];
        ea.contact_imbalance.Cc_factors = [1 1 1];
    end
end