function results = emg_simulation_core(cfg)
%% EMG_SIMULATION_CORE - Ядро симуляции распространения биопотенциалов
% =========================================================================
% Модульное ядро симуляции поверхностной ЭМГ
%
% ВХОД:
%   cfg - структура конфигурации (создаётся emg_configurator или загружается)
%
% ВЫХОД:
%   results - структура с результатами симуляции
%
% ИСПОЛЬЗОВАНИЕ:
%   cfg = load('my_config.mat'); cfg = cfg.cfg;
%   results = emg_simulation_core(cfg);
%
% АВТОР: EMG Simulation Framework
% ВЕРСИЯ: 2.0 (Модульная архитектура)
% =========================================================================

%=========================================================================
% PIPELINE OVERVIEW (high-level map)
% Этот файл логически разбит на 7 модулей:
%   [1] Геометрия -> build_geometry()
%   [2] MU-пулы -> build_motor_unit_pool()
%   [3] Солвер -> leadfield/FEM подготовка
%   [4] Главный цикл -> Fref -> drive -> spikes -> force -> sources -> phi
%   [5] Frontend -> контакт/усилитель/фильтры/децимация/шум
%   [6] Валидация -> RMS/спектр/Force–EMG
%   [7] Сохранение -> results + save_simulation_results()
% Изменения здесь — только комментарии/разметка, исполняемые строки не изменены.
%=========================================================================
    cfg = validate_and_complete_config(cfg);
    clear compute_neural_drive;
    
    %% ИНИЦИАЛИЗАЦИЯ
    fprintf('\n========================================================================\n');
    fprintf('  EMG SIMULATION CORE - INITIALIZATION\n');
    fprintf('========================================================================\n');
    fprintf('Solver Mode: %s\n', cfg.simulation.solver_mode);
    fprintf('Duration: %.2f s | Internal Fs: %d Hz | Output Fs: %d Hz\n', ...
        cfg.simulation.duration, cfg.simulation.fs_internal, cfg.simulation.fs_output);
    fprintf('Active Muscles: %d | Total Motor Units: %d\n', ...
        length(cfg.muscles), sum(cellfun(@(m) m.n_motor_units, cfg.muscles)));
    fprintf('Electrodes: %d sensors\n', length(cfg.electrode_arrays));
    fprintf('------------------------------------------------------------------------\n\n');
    
% Временная сетка внутреннего расчёта (fs_internal). Все спайки/источники считаются на ней.
    t = 0 : 1/cfg.simulation.fs_internal : cfg.simulation.duration;
% Число отсчётов внутреннего цикла. Далее по нему выделяются буферы под сигналы/силу/спайки.
    N_samples = length(t);
    
    %% МОДУЛЬ 1: ГЕОМЕТРИЯ
%  Задача: построить слои тканей/кости/мышцы и их геометрию для проводника.
    fprintf('[1/7] Building geometry...\n'); tic;
    geom = build_geometry(cfg);
    fprintf('      Geometry: %d tissue regions, Bones: %d, Muscles: %d\n', ...
        length(geom.tissues), size(geom.bones.positions, 1), length(cfg.muscles));
    toc_geom = toc; fprintf('      Time: %.2f s\n\n', toc_geom);
    
    %% МОДУЛЬ 2: МОТОНЕЙРОННЫЕ ПУЛЫ
%  Задача: собрать параметры MU и разместить их внутри мышцы (типы, пороги, CV, twitch).
    fprintf('[2/7] Building motor neuron pools...\n'); tic;
    mu_pools = cell(length(cfg.muscles), 1);
    for m_idx = 1:length(cfg.muscles)
        muscle_cfg = cfg.muscles{m_idx};
        fprintf('      Muscle %d/%d: %s (%d MUs)\n', m_idx, length(cfg.muscles), ...
            muscle_cfg.name, muscle_cfg.n_motor_units);
        mu_pools{m_idx} = build_motor_unit_pool(muscle_cfg, cfg, geom);
    end
    total_mus = sum(cellfun(@(p) length(p), mu_pools));
    fprintf('      Total motor units: %d\n', total_mus);
    toc_mu = toc; fprintf('      Time: %.2f s\n\n', toc_mu);
    
    %% МОДУЛЬ 3: СОЛВЕР
%  Задача: подготовить быстрый расчёт потенциалов: leadfield и/или FEM и/или Farina.
    fprintf('[3/7] Preparing volume conductor solver...\n'); tic;
    solver_data = struct();
    
    fprintf('      Generating basis sources...\n');
    basis_sources = generate_basis_sources(mu_pools, geom, cfg);
    fprintf('      Basis sources: %d\n', length(basis_sources));
    source_index = build_source_index(basis_sources, mu_pools);
    solver_data.basis_sources = basis_sources;
    solver_data.source_index = source_index;
    solver_data.n_sources = length(basis_sources);
    
    % === Инициализация библиотеки MUAP (если включена) ===
    solver_data.muap_library = [];
    if isfield(cfg, 'muap_library') && cfg.muap_library.enabled
        fprintf('      Initializing MUAP library...\n');
        solver_data.muap_library = initialize_muap_library(cfg, geom);
        if ~isempty(solver_data.muap_library) && solver_data.muap_library.is_computed
            fprintf('        MUAP library ready: %dx%dx%d grid\n', ...
                solver_data.muap_library.n_depth, solver_data.muap_library.n_cv, solver_data.muap_library.n_fat);
        end
    end
    
    % Стандартный leadfield (дипольная аппроксимация)
    if strcmp(cfg.simulation.solver_mode, 'leadfield') || strcmp(cfg.simulation.solver_mode, 'both')
        fprintf('      Computing leadfield matrices for %d electrode arrays...\n', length(cfg.electrode_arrays));
        solver_data.leadfield = cell(length(cfg.electrode_arrays), 1);
        for ea = 1:length(cfg.electrode_arrays)
            solver_data.leadfield{ea} = compute_leadfield_matrix(basis_sources, geom, cfg, ea);
            fprintf('        Array %d: %d sources x %d electrodes\n', ea, ...
                size(solver_data.leadfield{ea}, 2), size(solver_data.leadfield{ea}, 1));
        end
    end
    
    % === Farina цилиндрическая модель (НОВОЕ) ===
    if strcmp(cfg.simulation.solver_mode, 'farina')
        fprintf('      Computing Farina cylindrical leadfield for %d electrode arrays...\n', length(cfg.electrode_arrays));
        solver_data.leadfield = cell(length(cfg.electrode_arrays), 1);
        for ea = 1:length(cfg.electrode_arrays)
            solver_data.leadfield{ea} = compute_leadfield_farina(basis_sources, geom, cfg, ea);
            fprintf('        Array %d: %d sources x %d electrodes (Farina model)\n', ea, ...
                size(solver_data.leadfield{ea}, 2), size(solver_data.leadfield{ea}, 1));
        end
    end
    
    if strcmp(cfg.simulation.solver_mode, 'fem') || strcmp(cfg.simulation.solver_mode, 'both')
        fprintf('      Preparing FEM solver...\n');
        solver_data.fem_mesh = build_volume_mesh(geom, cfg);
        fprintf('      FEM mesh: %d nodes, %d elements\n', ...
            size(solver_data.fem_mesh.nodes, 1), size(solver_data.fem_mesh.elements, 1));
        solver_data.fem_stiffness = assemble_stiffness_matrix(solver_data.fem_mesh, geom, cfg);
        solver_data.fem = cell(length(cfg.electrode_arrays), 1);
        for ea = 1:length(cfg.electrode_arrays)
            solver_data.fem{ea} = prepare_fem_mappings(solver_data.fem_mesh, geom, cfg, basis_sources, ea);
        end
    end
    toc_solver = toc; fprintf('      Time: %.2f s\n\n', toc_solver);
    
    %% МОДУЛЬ 4: ГЛАВНЫЙ ЦИКЛ
%  Главный цикл (fs_internal). Порядок: Fref -> drive -> spikes -> force -> sources -> electrodes.
    fprintf('[4/7] Running main simulation loop...\n');
    fprintf('      Progress: '); tic;
    
    if cfg.save_data && ~exist(cfg.save_path, 'dir')
        mkdir(cfg.save_path);
    end
    
    n_electrode_arrays = length(cfg.electrode_arrays);
% Буфер «сырых» потенциалов на электродах ДО фронтенда; размер: [n_electrodes x N_samples] для каждого массива.
    phi_electrodes_raw = cell(n_electrode_arrays, 1);
    for ea = 1:n_electrode_arrays
        n_elec = cfg.electrode_arrays{ea}.n_electrodes;
        phi_electrodes_raw{ea} = zeros(n_elec, N_samples);
    end
    
% Буферы силы: итоговая (force_total) и целевая/эталонная (force_reference) — по мышцам, на fs_internal.
    force_total = zeros(length(cfg.muscles), N_samples);
    force_reference = zeros(length(cfg.muscles), N_samples);
% История спайков: sparse [n_MU x N_samples] для экономии памяти (обычно спайков мало).
    spike_history = cell(length(cfg.muscles), 1);
% История нейро-драйва (управляющий сигнал рекрутирования/частоты), по мышцам, на fs_internal.
    neural_drive_history = zeros(length(cfg.muscles), N_samples);
    
    for m = 1:length(cfg.muscles)
        spike_history{m} = sparse(length(mu_pools{m}), N_samples);
    end
    
    muscle_states = cell(length(cfg.muscles), 1);
% Предрасчёт максимальной силы каждой мышцы (F_max) для нормализации регулятора.
    F_max_muscles = zeros(length(cfg.muscles), 1);  % Максимальная сила каждой мышцы
    
    % ПАТЧ 1: Инициализация состояния common drive
    common_drive_state = struct();
    if isfield(cfg.motor_units, 'common_drive') && cfg.motor_units.common_drive.enabled
        cd_cfg = cfg.motor_units.common_drive;
        rng(cd_cfg.seed, 'twister');
        % AR(1) коэффициент для LPF
        common_drive_state.alpha = exp(-2*pi*cd_cfg.lpf_hz/cfg.simulation.fs_internal);
        common_drive_state.value = 0;
        common_drive_state.indep_alpha = exp(-2*pi*cd_cfg.indep_lpf_hz/cfg.simulation.fs_internal);
    else
        common_drive_state.alpha = 0;
        common_drive_state.value = 0;
        common_drive_state.indep_alpha = 0;
    end
    
    for m = 1:length(cfg.muscles)
        muscle_states{m}.force = 0;
        muscle_states{m}.twitch_history = struct([]);
        muscle_states{m}.last_spike_times = -inf(length(mu_pools{m}), 1);
        muscle_states{m}.e_integral = 0;
        muscle_states{m}.prev_error = 0;  % FIX: состояние для D-составляющей PID
        muscle_states{m}.prev_de_dt_f = 0;  % FIX: состояние для фильтра D-составляющей
        
                muscle_states{m}.prev_drive = 0;  % Для ограничения скорости изменения common drive
% ПАТЧ 1: Состояние для gamma renewal - следующий момент спайка
        n_mu = length(mu_pools{m});
        muscle_states{m}.next_spike_times = inf(n_mu, 1);  % Будет вычислено при первом рекрутировании
        muscle_states{m}.indep_noise = zeros(n_mu, 1);     % Независимый шум для каждого MU
        
        % ПАТЧ 2: Состояние активации для нелинейной механики силы
        muscle_states{m}.activation = zeros(n_mu, 1);      % Уровень активации a_i(t) для каждого MU
        muscle_states{m}.fatigue = zeros(n_mu, 1);         % Состояние утомления (0..1)
        
        % Вычисляем F_max для каждой мышцы (sigma * area)
        F_max_muscles(m) = cfg.muscles{m}.sigma * cfg.muscles{m}.cross_section_area * 1e4;
    end
    
    % === АВТО-КАЛИБРОВКА spike_gain ===
    % Линейная активационная модель: a_ss = sg / (1 - d), d = exp(-ISI/tau_decay)
    % Калибровка: при fr_max → a_ss = 1.0 → sg = 1 - exp(-1/(fr_max * tau_decay))
    if isfield(cfg.motor_units, 'force_dynamics') && cfg.motor_units.force_dynamics.enabled
        fd = cfg.motor_units.force_dynamics;
        needs_calibration = ~isfield(fd, 'spike_gain') || ...
            (ischar(fd.spike_gain) && strcmp(fd.spike_gain, 'auto'));
        
        if needs_calibration
            if isscalar(cfg.motor_units.firing_rate_max)
                fr_max_val = cfg.motor_units.firing_rate_max;
            else
                fr_max_val = max(cfg.motor_units.firing_rate_max);
            end
            tau_decay_vec = fd.tau_decay;
            spike_gain_vec = zeros(1, length(tau_decay_vec));
            for ti = 1:length(tau_decay_vec)
                spike_gain_vec(ti) = 1 - exp(-1 / (fr_max_val * tau_decay_vec(ti)));
            end
            cfg.motor_units.force_dynamics.spike_gain = spike_gain_vec;
            fprintf('      spike_gain auto-calibrated: [%.4f, %.4f, %.4f]\n', ...
                spike_gain_vec(1), spike_gain_vec(2), spike_gain_vec(3));
        end
    end
    
    % === ПРЕДРАСЧЁТ LUT «drive → сила» для каждой мышцы ===
    % Позволяет контроллеру использовать точный feedforward (обратная модель мышцы).
    force_drive_luts = cell(length(cfg.muscles), 1);
    use_v2 = isfield(cfg.motor_units, 'force_dynamics') && cfg.motor_units.force_dynamics.enabled;
    for m = 1:length(cfg.muscles)
        if use_v2
            force_drive_luts{m} = precompute_force_drive_curve(mu_pools{m}, cfg);
        else
            % Линейное приближение для V1 (twitch) модели
            lut0 = struct(); lut0.drive = [0 1]; lut0.force = [0 F_max_muscles(m)];
            lut0.F_max_actual = F_max_muscles(m);
            force_drive_luts{m} = lut0;
        end
        fprintf('      Muscle %d: F_max_actual=%.2f N, F_ref_max=%.2f N\n', ...
            m, force_drive_luts{m}.F_max_actual, cfg.muscles{m}.force_profile.F_max);
    end
    
% Список активных MU-событий в текущем окне muap_window: нужен, чтобы суммировать вклад MUAP во времени.
    active_events = cell(length(cfg.muscles), 1);
    for m = 1:length(cfg.muscles)
        active_events{m} = struct('mu_id', {}, 't0', {});
    end
    
    progress_marks = round(linspace(1, N_samples, 20));
    progress_counter = 1;
% Шаг интегрирования внутреннего цикла (сек).
    dt = 1 / cfg.simulation.fs_internal;
    
    for n = 1:N_samples
        current_time = t(n);
        
        % ПАТЧ 1: Обновление состояния common drive (общего для всех MU)
        if isfield(cfg.motor_units, 'common_drive') && cfg.motor_units.common_drive.enabled
            cd_cfg = cfg.motor_units.common_drive;
            % AR(1) фильтр для common drive: c(t) = alpha * c(t-1) + sqrt(1-alpha^2) * noise
            common_drive_state.value = common_drive_state.alpha * common_drive_state.value + ...
                sqrt(1 - common_drive_state.alpha^2) * randn();
        end
        
        for m_idx = 1:length(cfg.muscles)
            muscle_cfg = cfg.muscles{m_idx};
            mu_pool = mu_pools{m_idx};
            state = muscle_states{m_idx};
            
% (1) Формируем целевую силу для мышцы на текущем времени (профиль из cfg/параметров мышцы).
            F_ref_raw = compute_reference_force(current_time, muscle_cfg);
            force_reference(m_idx, n) = F_ref_raw;   % сохраняем “как задумано” для графика
            
% (2) Контроллер: LUT feedforward + PI → neural_drive (0..1).
            % Патч: приводим референс к достижимому максимуму данной мышцы (иначе контроллер всегда в saturation)
            Fmax_ref_cfg = muscle_cfg.force_profile.F_max;
            Fmax_actual   = force_drive_luts{m_idx}.F_max_actual;

            if Fmax_ref_cfg > 1e-9 && Fmax_actual > 1e-9
                F_ref = F_ref_raw * (Fmax_actual / Fmax_ref_cfg);
            else
                F_ref = F_ref_raw;
            end

            % страховка
            F_ref = max(0, min(F_ref, Fmax_actual));

            [neural_drive, state.e_integral, state.prev_error, state.prev_de_dt_f] = compute_neural_drive_per_muscle( ...
                F_ref, state.force, state.e_integral, state.prev_error, state.prev_de_dt_f, force_drive_luts{m_idx}, cfg);
            
            % FIX Bug 3: Если целевая сила ≤ 0, НЕМЕДЛЕННО сбросить контроллер
            % Это предотвращает "залипание" мышцы после окончания целевого профиля:
            % интегратор, predictive boost и slew rate не должны удерживать drive > 0
            force_is_off = (F_ref <= 0);
            if force_is_off
                neural_drive = 0;
                % Сбрасываем положительный интеграл мгновенно
                if state.e_integral > 0
                    state.e_integral = 0;
                end
            end
            
            % ПАТЧ: Ограничение скорости изменения neural drive (физиологичнее, убирает рывки PI)
            % FIX: асимметричный slew rate — спад в 3× быстрее подъёма
            % FIX Bug 3: slew rate не применяется при force_is_off (мгновенное обнуление)
            if ~force_is_off
            if ~isfield(cfg.motor_units, 'drive_slew_up_per_s')
                drive_slew_up = 6.0;    % 1/с (0->1 минимум за ~0.17 s)
            else
                drive_slew_up = cfg.motor_units.drive_slew_up_per_s;
            end
            if ~isfield(cfg.motor_units, 'drive_slew_down_per_s')
                drive_slew_down = 18.0;  % 1/с (1->0 минимум за ~0.06 s) — быстрый спад
            else
                drive_slew_down = cfg.motor_units.drive_slew_down_per_s;
            end
            % Обратная совместимость: если задан старый параметр
            if isfield(cfg.motor_units, 'drive_slew_per_s')
                drive_slew_up = cfg.motor_units.drive_slew_per_s;
                drive_slew_down = cfg.motor_units.drive_slew_per_s * 3.0;
            end
            du_max_up   = drive_slew_up   * (1 / cfg.simulation.fs_internal);
            du_max_down = drive_slew_down * (1 / cfg.simulation.fs_internal);
            if neural_drive >= state.prev_drive
                neural_drive = min(state.prev_drive + du_max_up, neural_drive);
            else
                neural_drive = max(state.prev_drive - du_max_down, neural_drive);
            end
            end  % if ~force_is_off
            state.prev_drive = neural_drive;

            neural_drive_history(m_idx, n) = neural_drive;
            
% (3) ПАТЧ 1: Генерация спайков с common drive и gamma renewal
            [spikes, state] = generate_spikes_at_time_v2(mu_pool, neural_drive, current_time, ...
                state, common_drive_state, cfg);
            spike_history{m_idx}(:, n) = spikes;
            
% (4) ПАТЧ 2: Механика с нелинейной активационной динамикой и утомлением
            state = compute_muscle_force_v2(spikes, mu_pool, state, current_time, cfg);
            force_total(m_idx, n) = state.force;
            
            if any(spikes)
                spk_ids = find(spikes);
                for kk = 1:numel(spk_ids)
% (5) Регистрируем событие MU (id + t0), чтобы позже построить MUAP-вклад в окне muap_window.
%     ПАТЧ 4: используем точное (субсэмпловое) время спайка из state,
%     а не квантованное current_time — устраняет спектральные артефакты.
                    active_events{m_idx}(end+1).mu_id = spk_ids(kk);
                    active_events{m_idx}(end).t0 = state.last_spike_times(spk_ids(kk));
                end
            end
            
            if ~isempty(active_events{m_idx})
                ages = current_time - [active_events{m_idx}.t0];
% Удаляем события старше muap_window: ограничиваем число активных вкладов и ускоряем расчёт.
                active_events{m_idx} = active_events{m_idx}(ages <= cfg.sources.muap_window);
            end
            
            if ~isempty(active_events{m_idx})
                active_mu_indices = [active_events{m_idx}.mu_id];
                spike_times = [active_events{m_idx}.t0];
                
% (6) Строим вектор текущих источников (basis) от всех активных MU-событий для данной мышцы.
                sources_current = compute_fiber_sources_at_time(...
                    active_mu_indices, mu_pool, current_time, spike_times, m_idx, solver_data, cfg);
                
                for ea = 1:n_electrode_arrays
                    if strcmp(cfg.simulation.solver_mode, 'leadfield') || ...
                       strcmp(cfg.simulation.solver_mode, 'farina') || ...
                       strcmp(cfg.simulation.solver_mode, 'both')
% (7a) Объёмный проводник через leadfield: phi = L * sources (быстро, линейно).
%      Режим 'farina' также использует leadfield, но с более точной физикой цилиндра.
                        phi_e = solver_data.leadfield{ea} * sources_current;
                    else
% (7b) Объёмный проводник через FEM: решаем уравнение Пуассона/Лапласа на сетке для текущих источников.
                        phi_e = solve_fem_for_sources(sources_current, solver_data, geom, cfg, ea);
                    end
% Суммируем вклад всех активных событий/мышц в потенциал текущего отсчёта (линейная суперпозиция).
                    phi_electrodes_raw{ea}(:, n) = phi_electrodes_raw{ea}(:, n) + phi_e(:);
                end
            end
            
            muscle_states{m_idx} = state;
        end
        
        if n == progress_marks(progress_counter)
            fprintf('=');
            progress_counter = progress_counter + 1;
        end
    end
    
    fprintf(' DONE\n');
    toc_sim = toc;
    fprintf('      Simulation time: %.2f s (%.2fx realtime)\n', toc_sim, cfg.simulation.duration / toc_sim);
    fprintf('\n');
    
    %% МОДУЛЬ 5: FRONTEND
%  Моделирование измерительного тракта (frontend).
%  Порядок: ground → merge → mains → contact → spatial/diff → filter → noise
    fprintf('[5/7] Processing through electrode frontend...\n'); tic;
    
    emg_output = cell(n_electrode_arrays, 1);
    decimation_factor = round(cfg.simulation.fs_internal / cfg.simulation.fs_output);
    
    % --- [5.1] Вычисляем потенциал на земле для каждого массива ---
    phi_ground = cell(n_electrode_arrays, 1);
    for ea = 1:n_electrode_arrays
        phi_ground{ea} = compute_ground_potential(phi_electrodes_raw{ea}, ...
            cfg.electrode_arrays{ea}, geom);
    end
    
    % --- [5.2] Объединение земель (если включено) ---
    if isfield(cfg, 'interference') && isfield(cfg.interference, 'ground_merge') ...
            && cfg.interference.ground_merge.enabled
        phi_ground = apply_ground_merge(phi_ground, cfg);
        fprintf('      Ground merge: %d group(s)\n', ...
            numel(cfg.interference.ground_merge.groups));
    end
    
    % Сохраняем "чистые" биологические потенциалы ДО сетевой помехи
    phi_electrodes_bio = cell(n_electrode_arrays, 1);
    phi_ground_bio = cell(n_electrode_arrays, 1);
    for ea = 1:n_electrode_arrays
        phi_electrodes_bio{ea} = phi_electrodes_raw{ea};
        phi_ground_bio{ea} = phi_ground{ea};
    end
    
    % --- [5.3] Сетевая помеха (если включена) ---
    if isfield(cfg, 'interference') && isfield(cfg.interference, 'mains') ...
            && cfg.interference.mains.enabled
        [phi_electrodes_raw, phi_ground] = apply_mains_interference( ...
            phi_electrodes_raw, phi_ground, cfg, t);
        fprintf('      Mains interference: %.0f Hz, %.2f mV peak\n', ...
            cfg.interference.mains.frequency, ...
            cfg.interference.mains.amplitude_Vp * 1000);
    end
    
    % --- [5.4] Основной тракт (для каждого массива) ---
    for ea = 1:n_electrode_arrays
        ea_cfg = cfg.electrode_arrays{ea};
        
% Контактная модель: каждый электрод имеет свою RC-цепь контакта.
% H_k(s) = sτ_k/(1+sτ_k) применяется к СЫРЫМ потенциалам (включая V_cm).
% GND не вычитается — INA сам обрабатывает дифференциальный и синфазный.
        [v_electrodes, v_gnd] = apply_contact_impedance_v2( ...
            phi_electrodes_raw{ea}, phi_ground{ea}, cfg, ea_cfg);
        
        % Диагностика дисбаланса контакта
        if isfield(ea_cfg, 'contact_imbalance') && ea_cfg.contact_imbalance.enabled
            imb = ea_cfg.contact_imbalance;
            Rc_base = ea_cfg.contact.Rc;
            Cc_base = ea_cfg.contact.Cc;
            Z_in_diag = 200e6;
            if isfield(ea_cfg.amplifier, 'input_impedance') && ea_cfg.amplifier.input_impedance > 0
                Z_in_diag = ea_cfg.amplifier.input_impedance;
            end
            fprintf('      Array %d (%s): Contact imbalance ON\n', ea, ea_cfg.name);
            fprintf('        Rc factors: [%.2f %.2f %.2f], Cc factors: [%.2f %.2f %.2f]\n', ...
                imb.Rc_factors, imb.Cc_factors);
            fprintf('        Z_in = %.0f МОм\n', Z_in_diag/1e6);
            omega50 = 2*pi*50;
            Rc1 = Rc_base * imb.Rc_factors(1); Rc3 = Rc_base * imb.Rc_factors(3);
            Cc1 = Cc_base * imb.Cc_factors(1); Cc3 = Cc_base * imb.Cc_factors(3);
            % Комплексный импеданс контакта
            Zc1 = Rc1 / (1 + 1i*omega50*Rc1*Cc1);
            Zc3 = Rc3 / (1 + 1i*omega50*Rc3*Cc3);
            % Делитель: H = Z_in/(Z_c+Z_in)
            H1 = Z_in_diag / (Zc1 + Z_in_diag);
            H3 = Z_in_diag / (Zc3 + Z_in_diag);
            cm_to_dm = abs(H1 - H3);
            fprintf('        |H1(50Hz)|=%.6f, |H3(50Hz)|=%.6f\n', abs(H1), abs(H3));
            fprintf('        |H1-H3| = %.6f (%.2f%% CM→DM)\n', cm_to_dm, cm_to_dm*100);
            fprintf('        DC: H1=%.6f, H3=%.6f\n', Z_in_diag/(Rc1+Z_in_diag), Z_in_diag/(Rc3+Z_in_diag));
            if isfield(cfg,'interference') && isfield(cfg.interference,'mains') && cfg.interference.mains.enabled
                V_cm_peak = cfg.interference.mains.amplitude_Vp;
                fprintf('        V_cm = %.1f мВ → артефакт ≈ %.1f мкВ\n', ...
                    V_cm_peak*1e3, cm_to_dm*V_cm_peak*1e6);
            else
                fprintf('        ⚠ Сетевая помеха ВЫКЛЮЧЕНА — дисбаланс контакта невидим!\n');
            end
        end
        
% ПАТЧ 9: Spatial filter (SD/DD/NDD/IR) перед инструментальным усилителем.
%   Если задан ea_cfg.spatial_filter, применяется пространственная фильтрация
%   вместо (или до) дифференциальных пар в apply_instrumentation_amplifier.
        if isfield(ea_cfg, 'spatial_filter') && ~isempty(ea_cfg.spatial_filter)
            [v_electrodes, sf_labels] = apply_spatial_filter(v_electrodes, ea_cfg);
            % После spatial filter каждый канал уже дифференциальный, 
            % поэтому усилитель работает в монопольном режиме
            ea_cfg_sf = ea_cfg;
            ea_cfg_sf.differential_pairs = [];  % Отключаем differential_pairs
            emg_amplified = apply_instrumentation_amplifier_v2(v_electrodes, v_gnd, ea_cfg_sf);
        else
% Инструментальный усилитель: дифференциальное усиление + CMRR + дисбаланс.
            emg_amplified = apply_instrumentation_amplifier_v2(v_electrodes, v_gnd, ea_cfg);
        end
% Аналоговая фильтрация (HP/LP/Notch) для имитации реального тракта перед АЦП.
        emg_filtered = apply_analog_filters(emg_amplified, cfg, ea_cfg);
        
% Децимация: приводим fs_internal -> fs_output (для записи/визуализации/дальнейшей обработки).
        emg_decimated = zeros(size(emg_filtered, 1), ceil(N_samples / decimation_factor));
        for ch = 1:size(emg_filtered, 1)
            emg_decimated(ch, :) = decimate(emg_filtered(ch, :), decimation_factor);
        end
% Добавляем измерительный шум (АЦП/внешние наводки), чтобы сигнал не был «идеально чистым».
        emg_output{ea} = add_measurement_noise(emg_decimated, cfg, ea_cfg);
    end
    
    t_output = downsample(t, decimation_factor);
    
    fprintf('      Processed %d electrode arrays\n', n_electrode_arrays);
    toc_frontend = toc; fprintf('      Time: %.2f s\n\n', toc_frontend);
    
    %% МОДУЛЬ 6: ВАЛИДАЦИЯ
%  Санити-валидация: диапазоны RMS, медианная частота, корреляция Force–EMG.
    fprintf('[6/7] Running validation checks...\n');
    validation = struct();
    validation.per_array = cell(n_electrode_arrays, 1);
    
    for ea = 1:n_electrode_arrays
        val = struct();
% RMS по каналам — грубый контроль амплитудного диапазона (в В; далее выводится в µV).
        emg_rms = sqrt(mean(emg_output{ea}.^2, 2));
        val.emg_rms = emg_rms;
        val.emg_amplitude_ok = all(emg_rms > 1e-6 & emg_rms < 5e-3);
        
        if size(emg_output{ea}, 1) > 0 && length(emg_output{ea}(1, :)) > 512
% Спектральный контроль: оценка PSD и медианной частоты (median frequency).
            [pxx, f] = pwelch(emg_output{ea}(1, :), hamming(512), 256, 512, cfg.simulation.fs_output);
            Pcum = cumsum(pxx);
            mf_idx = find(Pcum >= 0.5 * Pcum(end), 1, 'first');
            val.median_freq = f(mf_idx);
        else
            val.median_freq = NaN;
        end
        
        validation.per_array{ea} = val;
        fprintf('      Array %d: EMG RMS = %.2f µV, Median freq = %.1f Hz\n', ...
            ea, mean(emg_rms) * 1e6, val.median_freq);
    end
    
    force_sum = sum(force_total, 1);
    force_decimated = downsample(force_sum, decimation_factor);
    if ~isempty(emg_output{1})
        emg_envelope = abs(hilbert(emg_output{1}(1, :)));
        if std(force_decimated) > 1e-6 && std(emg_envelope) > 1e-12
% Корреляция envelope(EMG) и силы — ожидаемо положительная при росте рекрутирования/drive.
            validation.force_emg_corr = corr(force_decimated', emg_envelope');
        else
            validation.force_emg_corr = 0;
        end
    else
        validation.force_emg_corr = 0;
    end
    fprintf('      Force-EMG correlation: %.3f\n\n', validation.force_emg_corr);
    
    %% МОДУЛЬ 7: СОХРАНЕНИЕ
%  Упаковка результатов и сохранение (если включено).
    fprintf('[7/7] Saving results...\n');
    
% Итоговый пакет результатов. Сохраняем как «сырьё» (raw phi) так и после фронтенда (emg).
    results = struct();
    results.config = cfg;
    results.geometry = geom;
    results.motor_units = mu_pools;
    results.solver_data = solver_data;
    results.time = t_output;
    results.time_full = t;
    results.phi_electrodes_raw = phi_electrodes_raw;
    results.phi_electrodes_bio = phi_electrodes_bio;  % до сетевой помехи
    results.phi_ground = phi_ground;                   % потенциал земли (после помехи)
    results.phi_ground_bio = phi_ground_bio;           % потенциал земли (до помехи)
    results.emg = emg_output;
    results.force = force_total;
% Дополнительно храним силу, приведённую к fs_output для удобства совместного анализа с EMG.
    results.force_decimated = downsample(force_total', decimation_factor)';
    results.force_reference = force_reference;
    results.force_reference_decimated = downsample(force_reference', decimation_factor)';
    results.spike_history = spike_history;
    results.neural_drive_history = neural_drive_history;
    results.force_drive_luts = force_drive_luts;
    results.validation = validation;
    results.computation_time = struct('geometry', toc_geom, 'motor_units', toc_mu, ...
        'solver', toc_solver, 'simulation', toc_sim, 'frontend', toc_frontend);
    
    if cfg.save_data
        save_simulation_results(results, cfg);
    end
    
    fprintf('========================================================================\n');
    fprintf('  SIMULATION COMPLETE\n');
    fprintf('========================================================================\n');
    fprintf('Total computation time: %.2f s\n', sum(struct2array(results.computation_time)));
    if cfg.save_data
        fprintf('Results saved to: %s\n', cfg.save_path);
    end
    fprintf('========================================================================\n\n');
end

%% ========================================================================
%  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ

%--------------------------------------------------------------------------
% REFERENCE MAP (ключевые структуры и как они "текут" по пайплайну)
%
% cfg (input configuration)
%   cfg.simulation.*         : fs_internal/fs_output/duration/solver_mode
%   cfg.geometry.*           : параметры предплечья (радиусы слоёв, длина)
%   cfg.muscles{m}.*         : мышцы (геометрия, sigma, площадь, профили силы, n_motor_units)
%   cfg.motor_units.*        : диапазоны/распределения MU (S/FR/FF, thresholds, firing rates, twitch)
%   cfg.electrode_arrays{ea} : массивы электродов (геометрия, пары, усилитель/фильтры/контакт)
%   cfg.save_*               : параметры сохранения
%
% geom (built by build_geometry)
%   geom.tissues             : регионы тканей и проводимости
%   geom.bones               : геометрия костей
%   geom.muscles             : геометрия мышц (для размещения MU/волокон)
%   geom.surface             : поверхность кожи (для электродов)
%
% mu_pools{m} (built by build_motor_unit_pool)
%   mu_pool(k).type          : 'S'/'FR'/'FF'
%   mu_pool(k).thr           : порог рекрутирования (0..1 по drive)
%   mu_pool(k).cv            : скорость проведения (м/с)
%   mu_pool(k).twitch_*      : параметры twitch
%   mu_pool(k).fibers        : геометрия волокон MU (если используется)
%
% solver_data (prepared before main loop)
%   solver_data.basis_sources: предвычисленные источники (геометрия/ориентация)
%   solver_data.source_index : MU -> индексы источников
%   solver_data.leadfield{ea}: L матрицы (электроды x источники)
%   solver_data.fem_*        : FEM сетка/матрицы/маппинги (если включено)
%
% Runtime buffers (main loop)
%   force_reference(m,n)     : целевая сила мышцы m на fs_internal
%   neural_drive_history(m,n): управляющий drive u(t) 0..1
%   spike_history{m}(:,n)    : разреженная матрица спайков MU на fs_internal
%   force_total(m,n)         : текущая сила мышцы m на fs_internal
%   phi_electrodes_raw{ea}   : сырые потенциалы на электродах (до фронтенда)
%
% emg_output{ea} (frontend output)
%   Матрица [n_channels x N_out] на fs_output (после контакта/усилителя/фильтров/децимации/шума)
%--------------------------------------------------------------------------
% =========================================================================


%--------------------------------------------------------------------------
% MODULE: Configuration validation & normalization
%
% Purpose:
%   - Проверяет наличие обязательных полей cfg.
%   - Заполняет отсутствующие поля дефолтами (apply_defaults).
%   - Приводит устаревшие структуры (cfg.electrodes -> cfg.electrode_arrays).
%   - Запускает базовую авто-починку геометрии (validate_and_fix_geometry).
%
% Inputs:
%   cfg : struct
%       Внешняя конфигурация симуляции (из configurator / файла).
%
% Outputs:
%   cfg : struct
%       Конфигурация, безопасная для последующих модулей (геометрия/пул/солвер).
%
% Notes:
%   Здесь не должно быть тяжёлых вычислений — только проверка/нормализация.
%--------------------------------------------------------------------------
function cfg = validate_and_complete_config(cfg)
    if ~isfield(cfg, 'simulation'), error('Configuration must contain "simulation" field'); end
    if ~isfield(cfg, 'muscles') || isempty(cfg.muscles), error('Configuration must contain at least one muscle'); end
    
    defaults.simulation.duration = 1.0;
    defaults.simulation.fs_internal = 10000;
    defaults.simulation.fs_output = 2000;
    defaults.simulation.solver_mode = 'leadfield';
    
    defaults.geometry.type = 'parametric';
    defaults.geometry.length = 0.25;
    defaults.geometry.radius_outer = 0.035;
    defaults.geometry.skin_thickness = 0.0015;
    defaults.geometry.fat_thickness = 0.004;
    defaults.geometry.fascia_thickness = 0.0005;
    
    defaults.motor_units.types = {'S', 'FR', 'FF'};
    defaults.motor_units.type_distribution = [0.5, 0.3, 0.2];
    defaults.motor_units.cv_range = [3.0, 4.5, 6.0];
    defaults.motor_units.twitch_amplitude_range = [0.05, 0.3, 1.0];
    defaults.motor_units.twitch_rise_time = [0.080, 0.050, 0.030];
    defaults.motor_units.twitch_fall_time = [0.120, 0.070, 0.040];
    defaults.motor_units.recruitment_threshold_range = [0.01, 0.60]; % согласовано с configurator
    defaults.motor_units.firing_rate_min = [6, 8, 10];          % Гц по типам [S, FR, FF]
    defaults.motor_units.firing_rate_max = [22, 32, 42];        % Гц по типам [S, FR, FF]
    defaults.motor_units.firing_rate_gain = [25, 30, 35];       % прирост по типам [S, FR, FF]
    defaults.motor_units.isi_cv = 0.15;  % Увеличен для gamma renewal (типичный 0.10-0.25)
    defaults.motor_units.refractory_s = 0.003;  % Абсолютный рефрактерный период (3 мс)
    
    % ПАТЧ 1: Common drive параметры
    defaults.motor_units.common_drive = struct();
    defaults.motor_units.common_drive.enabled = true;
    defaults.motor_units.common_drive.strength = 0.15;       % Доля common drive (0..0.4)
    defaults.motor_units.common_drive.lpf_hz = 3.0;          % Полоса common drive (1..5 Гц)
    defaults.motor_units.common_drive.indep_strength = 0.10; % Независимый шум (0..0.2)
    defaults.motor_units.common_drive.indep_lpf_hz = 15.0;   % Полоса индивидуального шума
    defaults.motor_units.common_drive.sync_prob = 0.02;      % Вероятность синхронизации
    defaults.motor_units.common_drive.seed = 42;             % Seed для воспроизводимости
    
    % ПАТЧ 1: Gamma renewal модель спайков
    defaults.motor_units.spike_model = 'gamma_renewal';      % 'threshold' | 'gamma_renewal'
    
    % ПАТЧ 2: Параметры механики силы (нелинейная активация)
    defaults.motor_units.force_dynamics = struct();
    defaults.motor_units.force_dynamics.enabled = true;
    defaults.motor_units.force_dynamics.tau_rise = [0.020, 0.015, 0.010];   % Время нарастания активации (S,FR,FF)
    defaults.motor_units.force_dynamics.tau_decay = [0.120, 0.070, 0.040];  % ИСПРАВЛЕНО: = twitch_fall_time (S,FR,FF)
    defaults.motor_units.force_dynamics.hill_n = 3.0;        % Экспонента Hill (2..4)
    defaults.motor_units.force_dynamics.a50 = 0.35;          % Полумаксимальная активация (0.3..0.5)
    defaults.motor_units.force_dynamics.spike_gain = 'auto';  % 'auto' = авто-калибровка
    defaults.motor_units.force_dynamics.fatigue_enabled = false;
    defaults.motor_units.force_dynamics.fatigue_rate = 0.001;     % Скорость накопления утомления
    defaults.motor_units.force_dynamics.recovery_rate = 0.0005;   % Скорость восстановления
    defaults.motor_units.force_dynamics.fatigue_force_k = 0.3;    % Влияние утомления на силу
    defaults.motor_units.force_dynamics.fatigue_cv_k = 0.2;       % Влияние утомления на CV
    
    % ПАТЧ 3 + IAP Model: Биофизические параметры волокна для MUAP источника
    defaults.fibers = struct();
    defaults.fibers.mode = 'representative';   % 'representative' | 'all' | 'adaptive'
    defaults.fibers.use_biophysical_source = true;  % Использовать биофизическую модель источника
    
    % Параметры модели потенциала действия (IAP)
    defaults.fibers.iap_model = 'rosenfalck';  % 'rosenfalck' | 'hh' | 'fhn' | 'gaussian'
    defaults.fibers.Cm_uF_per_cm2 = 1.0;       % Ёмкость мембраны (мкФ/см²) - стандартное значение
    defaults.fibers.Cm_F_per_m2 = 0.01;        % Ёмкость мембраны (Ф/м²) = 1.0 мкФ/см²
    defaults.fibers.Vm_rest_mV = -85;          % Потенциал покоя (мВ)
    defaults.fibers.Vm_peak_mV = 30;           % Пиковый потенциал (мВ) - overshoot
    defaults.fibers.AP_amplitude_mV = 115;     % Полная амплитуда ПД (мВ)
    defaults.fibers.AP_duration_ms = 3.0;      % Длительность ПД (мс)
    
    % Геометрия волокон по типам MU [S, FR, FF]
    defaults.fibers.diam_range_um = [35, 50, 65];  % Диаметр волокон по типам (мкм)
    defaults.fibers.cv_range = [3.0, 4.0, 5.0];    % CV по типам (м/с) - связано с диаметром
    
    % Проводимости
    defaults.fibers.sigma_i = 1.0;             % Внутриклеточная проводимость (См/м)
    defaults.fibers.sigma_e = 0.4;             % Внеклеточная проводимость (См/м)
    defaults.fibers.Ri_Ohm_cm = 125;           % Внутриклеточное сопротивление (Ом·см)
    defaults.fibers.Rm_Ohm_cm2 = 4000;         % Сопротивление мембраны (Ом·см²)
    
    % Параметры модели Rosenfalck
    defaults.fibers.rosenfalck_A = 96;         % Коэффициент амплитуды (мВ/мм³)
    defaults.fibers.rosenfalck_lambda = 1.0;   % Постоянная длины (мм)
    
    % Температура (для HH модели)
    defaults.fibers.temperature = 37;          % Температура (°C)
    
    defaults.sources.muap_window = 0.030;  % 30 мс для захвата хвостов
    
    % === Параметры библиотеки MUAP (кеширование) ===
    defaults.muap_library = struct();
    defaults.muap_library.enabled = false;        % Использовать предрасчитанную библиотеку
    defaults.muap_library.cache_file = '';        % Путь к файлу кеша (пусто = не загружать)
    defaults.muap_library.auto_precompute = true; % Автоматически предрасчитывать если нет кеша
    defaults.muap_library.n_depth_points = 8;     % Число точек по глубине
    defaults.muap_library.n_cv_points = 8;        % Число точек по CV
    defaults.muap_library.n_fat_points = 4;       % Число точек по толщине жира
    defaults.muap_library.save_after_compute = true;  % Сохранять после расчёта
    
    % === Параметры модели Farina (цилиндрический объёмный проводник) ===
    defaults.solver = struct();
    defaults.solver.farina = struct();
    defaults.solver.farina.n_k_points = 64;      % Число точек интегрирования по k
    defaults.solver.farina.k_max = 1500;         % Максимальная пространственная частота (1/м)
    defaults.solver.farina.n_bessel_terms = 30;  % Число членов ряда Бесселя
    defaults.solver.farina.use_cache = true;     % Использовать кеширование
    
    % Реалистичные проводимости тканей (S/m)
    defaults.tissues.skin.sigma = 0.2;     % было 0.0002 - слишком мало!
    defaults.tissues.fat.sigma = 0.04;
    defaults.tissues.muscle.sigma_long = 0.6;
    defaults.tissues.muscle.sigma_trans = 0.15;
    defaults.tissues.fascia.sigma = 0.1;
    defaults.tissues.bone.sigma = 0.02;
    
    defaults.save_data = true;
    defaults.save_path = './emg_simulation_data';
    defaults.save_incremental = false;
    defaults.save_interval = 1.0;
    
    % === Сетевая помеха и объединение земель ===
    defaults.interference.mains.enabled = false;
    defaults.interference.mains.frequency = 50;
    defaults.interference.mains.amplitude_Vp = 1.0;  % 1 В peak — реалистично (IEC 60601: 1-20 В)
    defaults.interference.mains.n_harmonics = 3;
    defaults.interference.mains.harmonic_decay = 0.3;
    defaults.interference.mains.dc_offset_V = 0;
    defaults.interference.mains.dc_offset_spread_V = 0.005;
    defaults.interference.mains.phase_noise_deg = 5;
    defaults.interference.mains.amplitude_noise = 0.05;
    defaults.interference.ground_merge.enabled = false;
    defaults.interference.ground_merge.groups = {};
    
    cfg = apply_defaults(cfg, defaults);
    
    % Валидация геометрии - проверка наложений
    cfg = validate_and_fix_geometry(cfg);
    
    % === Дополнение мышц значениями по умолчанию (включая force_profile) ===
    for m = 1:length(cfg.muscles)
        muscle = cfg.muscles{m};
        
        % Базовые поля мышцы
        if ~isfield(muscle, 'sigma'), muscle.sigma = 26.8; end
        if ~isfield(muscle, 'cross_section_area'), muscle.cross_section_area = 2e-4; end
        if ~isfield(muscle, 'fiber_length'), muscle.fiber_length = 0.12; end
        if ~isfield(muscle, 'n_motor_units'), muscle.n_motor_units = 100; end
        if ~isfield(muscle, 'depth'), muscle.depth = 0.018; end
        if ~isfield(muscle, 'position_angle'), muscle.position_angle = 0; end
        if ~isfield(muscle, 'name'), muscle.name = sprintf('Muscle_%d', m); end
        
        % Вычисляем F_max мышцы
        F_max_muscle = muscle.sigma * muscle.cross_section_area * 1e4;  % Н
        
        % Force profile - КРИТИЧЕСКИ ВАЖНО для генерации силы
        if ~isfield(muscle, 'force_profile') || isempty(muscle.force_profile)
            fp = struct();
            fp.type = 'ramp_hold';
            fp.F_max = F_max_muscle * 0.3;  % 30% от максимальной силы
            fp.F_max_percent = 30;
            fp.ramp_time = 0.25;
            fp.hold_time = 0.35;
            fp.ramp_down_time = 0.25;
            fp.step_time = 0.2;
            fp.frequency = 0.5;
            fp.custom_data = [];
            muscle.force_profile = fp;
        else
            % Проверяем и дополняем существующий force_profile
            fp = muscle.force_profile;
            if ~isfield(fp, 'type'), fp.type = 'ramp_hold'; end
            if ~isfield(fp, 'F_max') || fp.F_max == 0
                % Вычисляем F_max если не задан или равен 0
                if isfield(fp, 'F_max_percent') && fp.F_max_percent > 0
                    fp.F_max = F_max_muscle * fp.F_max_percent / 100;
                else
                    fp.F_max = F_max_muscle * 0.3;  % По умолчанию 30%
                end
            end
            if ~isfield(fp, 'ramp_time'), fp.ramp_time = 0.25; end
            if ~isfield(fp, 'hold_time'), fp.hold_time = 0.35; end
            if ~isfield(fp, 'ramp_down_time'), fp.ramp_down_time = 0.25; end
            if ~isfield(fp, 'step_time'), fp.step_time = 0.2; end
            if ~isfield(fp, 'frequency'), fp.frequency = 0.5; end
            if ~isfield(fp, 'custom_data'), fp.custom_data = []; end
            muscle.force_profile = fp;
        end
        
        cfg.muscles{m} = muscle;
    end
    
    % === ВАЛИДАЦИЯ force_dynamics: принудительная рекалибровка для старых конфигов ===
    if isfield(cfg.motor_units, 'force_dynamics')
        fd = cfg.motor_units.force_dynamics;
        
        % tau_decay ДОЛЖЕН соответствовать twitch_fall_time — иначе модель неконсистентна
        if isfield(fd, 'tau_decay') && isnumeric(fd.tau_decay)
            tft = cfg.motor_units.twitch_fall_time;
            if any(abs(fd.tau_decay - tft) > 0.005)
                fprintf('      [Config fix] tau_decay synced with twitch_fall_time: [%.3f,%.3f,%.3f]\n', tft(1), tft(2), tft(3));
                cfg.motor_units.force_dynamics.tau_decay = tft;
            end
        end
        
        % spike_gain: если числовой и слишком маленький — пересчитать (старые конфиги с 0.03)
        if isfield(fd, 'spike_gain') && isnumeric(fd.spike_gain)
            if any(fd.spike_gain < 0.05)
                fprintf('      [Config fix] spike_gain=%.3f too low, forcing auto-calibration\n', fd.spike_gain(1));
                cfg.motor_units.force_dynamics.spike_gain = 'auto';
            end
        end
    end
    
    if isfield(cfg, 'electrodes') && ~isfield(cfg, 'electrode_arrays')
        ea = struct();
        ea.name = 'Primary';
        ea.n_electrodes = 3;
        ea.shape = cfg.electrodes.shape;
        ea.size = cfg.electrodes.size;
        ea.spacing = cfg.electrodes.spacing;
        ea.positions = cfg.electrodes.positions;
        ea.position_z = cfg.geometry.electrode_position_z;
        ea.angle = cfg.muscles{1}.position_angle;
        ea.array_rotation = 0;  % 0° = вдоль Z (мышечных волокон), 90° = перпендикулярно
        ea.contact = cfg.electrodes.contact;
        ea.differential_pairs = [1, 3];
        ea.reference_electrode = 2;
        
        if isfield(cfg, 'amplifier')
            ea.amplifier = cfg.amplifier;
        else
            ea.amplifier.gain = 1000;
            ea.amplifier.cmrr_db = 90;
            ea.amplifier.noise_density = 5e-9;
            ea.amplifier.input_impedance = 200e6;  % 200 МОм (типичное Z_cm_in INA при 50 Гц)
            ea.amplifier.highpass_cutoff = 20;
            ea.amplifier.lowpass_cutoff = 450;
            ea.amplifier.notch_freq = 50;
            ea.amplifier.notch_bw = 2;
        end
        cfg.electrode_arrays = {ea};
    end
    
    if ~isfield(cfg, 'electrode_arrays') || isempty(cfg.electrode_arrays)
        error('Configuration must contain electrode_arrays');
    end
    
    % --- Map configurator field 'rotation_deg' -> core field 'array_rotation'
    for ea_i = 1:length(cfg.electrode_arrays)
        if isfield(cfg.electrode_arrays{ea_i}, 'rotation_deg') && ...
                ~isfield(cfg.electrode_arrays{ea_i}, 'array_rotation')
            cfg.electrode_arrays{ea_i}.array_rotation = cfg.electrode_arrays{ea_i}.rotation_deg;
        end
        if ~isfield(cfg.electrode_arrays{ea_i}, 'array_rotation')
            cfg.electrode_arrays{ea_i}.array_rotation = 0;
        end
        
        % --- Позиция reference электрода ---
        if ~isfield(cfg.electrode_arrays{ea_i}, 'ref_position')
            cfg.electrode_arrays{ea_i}.ref_position = struct(...
                'custom_enabled', false, ...
                'angle', cfg.electrode_arrays{ea_i}.angle, ...
                'position_z', cfg.electrode_arrays{ea_i}.position_z);
        end
        
        % --- Электрод земли ---
        if ~isfield(cfg.electrode_arrays{ea_i}, 'ground_electrode')
            cfg.electrode_arrays{ea_i}.ground_electrode = struct(...
                'enabled', false, ...
                'angle', cfg.electrode_arrays{ea_i}.angle + 90, ...
                'position_z', 0.06, ...
                'Rc', 100e3, 'Cc', 100e-9);
        end
        
        % --- Дисбаланс контакта ---
        if ~isfield(cfg.electrode_arrays{ea_i}, 'contact_imbalance')
            cfg.electrode_arrays{ea_i}.contact_imbalance = struct(...
                'enabled', false, ...
                'Rc_factors', [1 1 1], ...
                'Cc_factors', [1 1 1], ...
                'Rc_ground_factor', 1.0, ...
                'Cc_ground_factor', 1.0);
        end
    end
end

%--------------------------------------------------------------------------
% MODULE: Geometry sanity-check (radii & overlaps)
%
% Purpose:
%   - Проверяет корректность радиусов слоёв: skin -> fat -> fascia -> muscle.
%   - При необходимости уменьшает толщины, чтобы избежать отрицательных радиусов.
%   - Это "предохранитель" от некорректных конфигов (а не физически точный оптимизатор).
%
% Inputs/Outputs:
%   cfg.geometry.* : использует radius_outer и толщины слоёв; может их скорректировать.
%
% Important:
%   Любое авто-исправление выводится warning-ом, т.к. меняет модель.
%--------------------------------------------------------------------------

function cfg = validate_and_fix_geometry(cfg)
    % Проверка и автоматическое исправление геометрии
    
    R_skin = cfg.geometry.radius_outer;
    R_fat = R_skin - cfg.geometry.skin_thickness;
    R_fascia = R_fat - cfg.geometry.fat_thickness;
    R_muscle = R_fascia - cfg.geometry.fascia_thickness;
    
    % Проверка радиусов слоёв
    if R_fat <= 0
        warning('EMG:Geometry', 'Fat radius <= 0, reducing skin thickness');
        cfg.geometry.skin_thickness = R_skin * 0.04;
        R_fat = R_skin - cfg.geometry.skin_thickness;
    end
    if R_fascia <= 0
        warning('EMG:Geometry', 'Fascia radius <= 0, reducing fat thickness');
        cfg.geometry.fat_thickness = R_fat * 0.1;
        R_fascia = R_fat - cfg.geometry.fat_thickness;
    end
    if R_muscle <= 0
        warning('EMG:Geometry', 'Muscle radius <= 0, reducing fascia thickness');
        cfg.geometry.fascia_thickness = R_fascia * 0.02;
        R_muscle = R_fascia - cfg.geometry.fascia_thickness;
    end
    
    % Проверка костей
    if isfield(cfg.geometry, 'bones')
        bones = cfg.geometry.bones;
        for b = 1:size(bones.positions, 1)
            bx = bones.positions(b, 1);
            by = bones.positions(b, 2);
            br = bones.radii(b);
            bone_dist = sqrt(bx^2 + by^2);
            
            % Кость не должна выходить за пределы мышечной области
            if bone_dist + br > R_muscle * 0.95
                warning('EMG:Geometry', 'Bone %d exceeds muscle area, adjusting position', b);
                max_dist = R_muscle * 0.9 - br;
                if max_dist < 0, max_dist = R_muscle * 0.5; bones.radii(b) = max_dist * 0.3; end
                if bone_dist > 0
                    scale = max_dist / bone_dist;
                    bones.positions(b, :) = bones.positions(b, :) * scale;
                end
            end
        end
        cfg.geometry.bones = bones;
    end
    
    % Проверка мышц
    for m = 1:length(cfg.muscles)
        muscle = cfg.muscles{m};
        angle = muscle.position_angle * pi/180;
        depth = muscle.depth;
        cx = depth * cos(angle);
        cy = depth * sin(angle);
        
        area = max(muscle.cross_section_area, eps);
        muscle_r = sqrt(area / pi);
        
        % Мышца не должна выходить за пределы мышечной области
        if depth + muscle_r > R_muscle * 0.98
            warning('EMG:Geometry', 'Muscle "%s" exceeds muscle area, adjusting depth', muscle.name);
            cfg.muscles{m}.depth = max(0.001, R_muscle * 0.9 - muscle_r);
        end
        
        % Проверка пересечения с костями
        if isfield(cfg.geometry, 'bones')
            bones = cfg.geometry.bones;
            for b = 1:size(bones.positions, 1)
                bx = bones.positions(b, 1);
                by = bones.positions(b, 2);
                br = bones.radii(b);
                
                dist_to_bone = sqrt((cx-bx)^2 + (cy-by)^2);
                min_dist = muscle_r + br + 0.003;  % 3мм зазор
                
                if dist_to_bone < min_dist && dist_to_bone > 0
                    warning('EMG:Geometry', 'Muscle "%s" overlaps with bone %d, adjusting position', muscle.name, b);
                    
                    % Сдвигаем мышцу от кости
                    dx = cx - bx;
                    dy = cy - by;
                    d = sqrt(dx^2 + dy^2);
                    
                    new_cx = bx + dx/d * min_dist;
                    new_cy = by + dy/d * min_dist;
                    
                    new_depth = sqrt(new_cx^2 + new_cy^2);
                    new_angle = atan2(new_cy, new_cx) * 180/pi;
                    
                    cfg.muscles{m}.depth = new_depth;
                    cfg.muscles{m}.position_angle = new_angle;
                end
            end
        end
    end
    
    fprintf('  Geometry validation: OK\n');
end

%--------------------------------------------------------------------------
% MODULE: Default value injection (recursive merge)
%
% Purpose:
%   - Рекурсивно дополняет cfg значениями из defaults, НЕ перетирая то, что уже задано.
%   - Используется только на этапе валидации конфигурации.
%
% Contract:
%   - Поля, заданные пользователем, имеют приоритет.
%   - Если поле отсутствует в cfg, оно добавляется из defaults.
%--------------------------------------------------------------------------

function cfg = apply_defaults(cfg, defaults)

    fields = fieldnames(defaults);
    for i = 1:length(fields)
        f = fields{i};
        if ~isfield(cfg, f)
            cfg.(f) = defaults.(f);
        elseif isstruct(defaults.(f)) && isstruct(cfg.(f))
            cfg.(f) = apply_defaults(cfg.(f), defaults.(f));
        end
    end
end

%--------------------------------------------------------------------------
% MODULE: Geometry builder (forearm + tissues + muscles + electrodes)
%
% Purpose:
%   - Формирует геометрию объёма проводника: слои тканей, кости, мышцы.
%   - Подготавливает поверхность кожи/сетку для размещения электродов.
%
% Outputs (geom):
%   geom.tissues : массив регионов тканей с проводимостями/границами
%   geom.bones   : кости (позиции/радиусы/контуры)
%   geom.muscles : геометрия мышц (контуры/оси/границы)
%   geom.surface : поверхность кожи (узлы/треугольники/нормали) — для электродов
%
% Notes:
%   Геометрия используется и leadfield-ом, и FEM (если включён).
%--------------------------------------------------------------------------
function geom = build_geometry(cfg)

    L = cfg.geometry.length;
    R_skin = cfg.geometry.radius_outer;
    R_fat = R_skin - cfg.geometry.skin_thickness;
    R_fascia = R_fat - cfg.geometry.fat_thickness;
    R_muscle = R_fascia - cfg.geometry.fascia_thickness;
    
    geom = struct();
    geom.type = cfg.geometry.type;
    geom.length = L;
    geom.radii = struct('skin', R_skin, 'fat', R_fat, 'fascia', R_fascia, 'muscle', R_muscle);
    
    if isfield(cfg.geometry, 'bones')
        geom.bones = cfg.geometry.bones;
    else
        geom.bones = struct('positions', [0.015, 0; -0.015, 0], 'radii', [0.004, 0.012]);
    end
    
    n_circ = 64; n_long = 50;
    theta = linspace(0, 2*pi, n_circ);
    z_surf = linspace(0, L, n_long);
    [Theta, Z] = meshgrid(theta, z_surf);
    X = R_skin * cos(Theta);
    Y = R_skin * sin(Theta);
    
    geom.surface.nodes = [X(:), Y(:), Z(:)];
    geom.surface.connectivity = delaunay(Theta(:), Z(:));
    
    geom.electrode_arrays = cell(length(cfg.electrode_arrays), 1);
    for ea = 1:length(cfg.electrode_arrays)
        geom.electrode_arrays{ea} = compute_electrode_positions(cfg.electrode_arrays{ea}, R_skin, L);
        % Диагностика: показываем ориентацию массива
        rot_deg = 0;
        if isfield(cfg.electrode_arrays{ea}, 'array_rotation')
            rot_deg = cfg.electrode_arrays{ea}.array_rotation;
        end
        fprintf('      Array %d (%s): angle=%.0f°, rotation=%.0f° (%s)\n', ea, ...
            cfg.electrode_arrays{ea}.name, cfg.electrode_arrays{ea}.angle, rot_deg, ...
            ternary_str(abs(rot_deg) < 5, 'along fibers', ...
            ternary_str(abs(rot_deg - 90) < 5, 'perpendicular', 'oblique')));
    end
    
    geom.tissues = {'skin', 'fat', 'fascia', 'muscle', 'bone'};
    
    geom.muscles = cell(length(cfg.muscles), 1);
    for m = 1:length(cfg.muscles)
        geom.muscles{m} = compute_muscle_geometry(cfg.muscles{m}, geom);
    end
end

%--------------------------------------------------------------------------
% MODULE: Electrode placement on skin surface
%
% Purpose:
%   - По параметрам electrode array (форма/размер/spacing/angle/position_z)
%     вычисляет координаты электродов в 3D на поверхности кожи.
%
% Inputs:
%   ea_cfg : struct (один массив электродов)
%   R_skin : radius_outer кожи (м)
%   L      : длина сегмента предплечья (м)
%
% Output:
%   elec_geom.positions : [n_electrodes x 3] координаты (м)
%
% Notes:
%   Важно: это геометрия электродов (куда "снимаем"), а не модель контакта.
%--------------------------------------------------------------------------
function elec_geom = compute_electrode_positions(ea_cfg, R_skin, L)
% compute_electrode_positions - Вычисляет 3D позиции электродов на поверхности цилиндра
%
% Параметры:
%   ea_cfg.angle          : азимутальный угол центра массива на цилиндре (градусы)
%   ea_cfg.array_rotation : поворот оси массива (градусы):
%                           0°  = электроды вдоль Z (параллельно мышечным волокнам)
%                           90° = электроды вдоль окружности (перпендикулярно волокнам)
%   ea_cfg.position_z     : координата Z центра массива
%   ea_cfg.spacing        : межэлектродное расстояние (м)
%   ea_cfg.positions      : [n x 2] пользовательские (x_local, y_local) — опционально
%
% Выход:
%   elec_geom.positions_3d : [3 x n_electrodes] координаты на поверхности цилиндра

    elec_geom = struct();
    elec_geom.shape = ea_cfg.shape;
    elec_geom.size = ea_cfg.size;
    elec_geom.n_electrodes = ea_cfg.n_electrodes;
    
    z_elec = ea_cfg.position_z;
    angle = ea_cfg.angle * pi/180;
    
    % FIX: поворот оси массива (0° = вдоль Z, 90° = вдоль окружности)
    if isfield(ea_cfg, 'array_rotation')
        array_rot = ea_cfg.array_rotation * pi/180;
    else
        array_rot = 0;  % По умолчанию вдоль Z (классическая sEMG ориентация)
    end
    
    elec_geom.positions_3d = zeros(3, ea_cfg.n_electrodes);
    
    if isfield(ea_cfg, 'positions') && ~isempty(ea_cfg.positions)
        % Пользовательские позиции: (x_local, y_local) в локальной СК массива
        for e = 1:ea_cfg.n_electrodes
            x_local = ea_cfg.positions(e, 1);  % Вдоль главной оси массива
            y_local = ea_cfg.positions(e, 2);  % Перпендикулярно главной оси
            
            % FIX: Применяем поворот массива к локальным координатам
            % Главная ось (x_local) проецируется на Z и тангенциальное направление
            x_rot = x_local * cos(array_rot) - y_local * sin(array_rot);  % проекция на Z
            y_rot = x_local * sin(array_rot) + y_local * cos(array_rot);  % проекция на тангенциальное
            
            elec_geom.positions_3d(:, e) = [R_skin * cos(angle + y_rot/R_skin); ...
                                            R_skin * sin(angle + y_rot/R_skin); z_elec + x_rot];
        end
    else
        % Линейный массив с равным spacing
        spacing = ea_cfg.spacing;
        for e = 1:ea_cfg.n_electrodes
            offset = (e - (ea_cfg.n_electrodes + 1)/2) * spacing;
            
            % FIX: offset проецируется с учётом array_rotation
            % offset вдоль главной оси массива → разложение на dz и d_tangential
            dz = offset * cos(array_rot);            % вклад в Z-направление
            d_tang = offset * sin(array_rot);        % вклад в тангенциальное направление
            
            elec_geom.positions_3d(:, e) = [R_skin * cos(angle + d_tang/R_skin); ...
                                            R_skin * sin(angle + d_tang/R_skin); z_elec + dz];
        end
    end
    
    % --- Произвольная позиция reference электрода (E2) ---
    % Если ref_position.custom_enabled = true, перемещаем средний электрод
    % (reference) в заданные координаты (angle, position_z) на цилиндре.
    if isfield(ea_cfg, 'ref_position') && ea_cfg.ref_position.custom_enabled
        ref_idx = ceil(ea_cfg.n_electrodes / 2);  % E2 = средний
        ref_angle = ea_cfg.ref_position.angle * pi / 180;
        ref_z = ea_cfg.ref_position.position_z;
        elec_geom.positions_3d(:, ref_idx) = [R_skin * cos(ref_angle); ...
                                               R_skin * sin(ref_angle); ...
                                               ref_z];
    end
end

%--------------------------------------------------------------------------
% MODULE: Muscle geometry (cross-section + placement)
%
% Purpose:
%   - Строит поперечное сечение мышцы и её положение относительно костей/осей.
%   - Даёт опорную геометрию для размещения MU и волокон.
%
% Output:
%   muscle_geom: struct с полями (центр/радиусы/угол/границы/ось и т.п.)
%--------------------------------------------------------------------------
function muscle_geom = compute_muscle_geometry(muscle_cfg, geom)
    muscle_geom = struct();
    muscle_geom.name = muscle_cfg.name;
    angle = muscle_cfg.position_angle * pi/180;
    depth = muscle_cfg.depth;
    muscle_geom.center = [depth * cos(angle); depth * sin(angle); geom.length/2];
    muscle_geom.angle = angle;
    muscle_geom.depth = depth;
    
    if isfield(muscle_cfg, 'polygon') && ~isempty(muscle_cfg.polygon)
        muscle_geom.type = 'polygon';
        muscle_geom.vertices = muscle_cfg.polygon;
    else
        muscle_geom.type = 'ellipse';
        area = muscle_cfg.cross_section_area;
        aspect = 1.5;
        muscle_geom.radii = [sqrt(area * aspect / pi), sqrt(area / (pi * aspect))];
    end
    
    if isfield(muscle_cfg, 'fascia_thickness')
        muscle_geom.fascia_thickness = muscle_cfg.fascia_thickness;
    else
        muscle_geom.fascia_thickness = 0.0003;
    end
end

%--------------------------------------------------------------------------
% MODULE: Motor Unit pool synthesis (types, thresholds, twitch, CV, fibers)
%
% Purpose:
%   - Создаёт массив MU для конкретной мышцы:
%       * тип MU (S/FR/FF)
%       * порог рекрутирования
%       * параметры частоты разрядов
%       * параметры twitch (амплитуда, времена)
%       * скорость проведения (CV)
%       * размещение MU/волокон внутри мышечной геометрии
%
% Inputs:
%   muscle_cfg : конфигурация одной мышцы
%   cfg        : общая конфигурация (диапазоны, распределения)
%   geom       : геометрия (для ограничений и исключения костей)
%
% Output:
%   mu_pool : struct array, mu_pool(k) описывает один MU (параметры + геометрия)
%
% Notes:
%   Этот модуль задаёт "микро-уровень" модели: от него зависят сила и ЭМГ.
%--------------------------------------------------------------------------
function mu_pool = build_motor_unit_pool(muscle_cfg, cfg, geom)
    n_mu = muscle_cfg.n_motor_units;
    
    type_dist = cfg.motor_units.type_distribution;
    type_cumsum = cumsum(type_dist);
    
    sigma = muscle_cfg.sigma;
    area_cm2 = muscle_cfg.cross_section_area * 1e4;
    F_max_muscle = sigma * area_cm2;
    
    rel_amp = cfg.motor_units.twitch_amplitude_range;
    n_types = [round(n_mu * type_dist(1)), round(n_mu * type_dist(2)), 0];
    n_types(3) = n_mu - n_types(1) - n_types(2);
    total_rel_force = n_types(1) * rel_amp(1) + n_types(2) * rel_amp(2) + n_types(3) * rel_amp(3);
    
    % Учитываем Hill(1.0) при масштабировании: при полном тетанусе (activation=1)
    % F_total = sum(twitch_amp_i * Hill(1)) = Hill(1) * sum(twitch_amp_i) = F_max_muscle
    % => sum(twitch_amp_i) = F_max_muscle / Hill(1)
    if isfield(cfg.motor_units, 'force_dynamics') && cfg.motor_units.force_dynamics.enabled
        hill_n = cfg.motor_units.force_dynamics.hill_n;
        a50 = cfg.motor_units.force_dynamics.a50;
        Hill_at_one = 1 / (1 + a50^hill_n);  % Hill(a=1.0) ≈ 0.959
    else
        Hill_at_one = 1.0;  % Для V1 модели (twitch summation) — без Hill
    end
    force_scale = F_max_muscle / (Hill_at_one * max(total_rel_force, eps));
    
    % Получаем параметры мышцы для генерации позиций
    angle = muscle_cfg.position_angle * pi/180;
    depth = muscle_cfg.depth;
    muscle_center_xy = [depth * cos(angle); depth * sin(angle)];
    
    % Получаем приблизительный радиус мышцы
    muscle_area = muscle_cfg.cross_section_area;
    muscle_radius = sqrt(muscle_area / pi);
    
    % Проверяем, есть ли предгенерированные позиции ДЕ
    has_pregenerated_positions = isfield(muscle_cfg, 'mu_positions') && ...
        ~isempty(muscle_cfg.mu_positions) && size(muscle_cfg.mu_positions, 1) >= n_mu;
    has_pregenerated_types = isfield(muscle_cfg, 'mu_types') && ...
        ~isempty(muscle_cfg.mu_types) && length(muscle_cfg.mu_types) >= n_mu;
    
    % Проверяем наличие полигона
    has_polygon = isfield(muscle_cfg, 'polygon') && ~isempty(muscle_cfg.polygon) && size(muscle_cfg.polygon, 1) >= 3;
    if has_polygon
        poly_pts = muscle_cfg.polygon + muscle_center_xy';
        poly_min_x = min(poly_pts(:,1));
        poly_max_x = max(poly_pts(:,1));
        poly_min_y = min(poly_pts(:,2));
        poly_max_y = max(poly_pts(:,2));
    end
    
    % Используем детерминированный seed для воспроизводимости
    if ~has_pregenerated_positions
        seed_value = round(abs(muscle_cfg.position_angle * 1000 + muscle_cfg.depth * 1e6 + n_mu));
        rng(seed_value, 'twister');
    end
    
    % Базовое число волокон по типам (из конфига или дефолт)
    if isfield(cfg.motor_units, 'n_fibers_range') && length(cfg.motor_units.n_fibers_range) >= 3
        n_fibers_base = cfg.motor_units.n_fibers_range;
    else
        n_fibers_base = [50, 150, 300];  % S, FR, FF по умолчанию
    end
    
    % Получаем параметры firing rate (могут быть скалярами или векторами по типам)
    fr_min_cfg = cfg.motor_units.firing_rate_min;
    fr_max_cfg = cfg.motor_units.firing_rate_max;
    fr_gain_cfg = cfg.motor_units.firing_rate_gain;
    
    % Получаем экспоненту для нелинейного порога
    if isfield(cfg.motor_units, 'threshold_exponent')
        thr_exp = cfg.motor_units.threshold_exponent;
    else
        thr_exp = 2.0;  % по умолчанию
    end
    
    % ========== ШАГ 1: Генерируем все MU с базовыми параметрами ==========
    temp_mu = struct();
    for i = 1:n_mu
        % Определяем тип ДЕ
        if has_pregenerated_types
            mu_type_idx = muscle_cfg.mu_types(min(i, length(muscle_cfg.mu_types)));
            if mu_type_idx < 1 || mu_type_idx > 3, mu_type_idx = 1; end
        else
            r = rand();
            if r < type_cumsum(1), mu_type_idx = 1;
            elseif r < type_cumsum(2), mu_type_idx = 2;
            else, mu_type_idx = 3;
            end
        end
        
        temp_mu(i).type_index = mu_type_idx;
        temp_mu(i).type = cfg.motor_units.types{mu_type_idx};
        
        % Базовая амплитуда twitch с вариацией внутри типа
        base_amp = cfg.motor_units.twitch_amplitude_range(mu_type_idx);
        temp_mu(i).twitch_amplitude = base_amp * (0.7 + 0.6*rand()) * force_scale;
        
        temp_mu(i).twitch_rise_time = cfg.motor_units.twitch_rise_time(mu_type_idx) * (0.9 + 0.2*rand());
        temp_mu(i).twitch_fall_time = cfg.motor_units.twitch_fall_time(mu_type_idx) * (0.9 + 0.2*rand());
        
        temp_mu(i).cv = cfg.motor_units.cv_range(mu_type_idx) + randn() * 0.3;
        
        % Число волокон с вариацией (из конфига)
        temp_mu(i).n_fibers = round(n_fibers_base(mu_type_idx) * (0.7 + 0.6*rand()));
        
        % Вычисляем "размер" MU для size principle (пропорционален силе)
        % size = twitch_amplitude * n_fibers (эффективная сила MU)
        temp_mu(i).size = temp_mu(i).twitch_amplitude * temp_mu(i).n_fibers;
        
        % Firing rate параметры (типо-зависимые — начальные значения)
        % ПАТЧ 5: при onion_skin = true будут перезаписаны после назначения порогов
        if length(fr_min_cfg) >= 3
            temp_mu(i).fr_min = fr_min_cfg(mu_type_idx);
            temp_mu(i).fr_max = fr_max_cfg(mu_type_idx);
            temp_mu(i).fr_gain = fr_gain_cfg(mu_type_idx);
        else
            temp_mu(i).fr_min = fr_min_cfg(1);
            temp_mu(i).fr_max = fr_max_cfg(1);
            temp_mu(i).fr_gain = fr_gain_cfg(1);
        end
        
        % ДОПОЛНИТЕЛЬНАЯ МОДУЛЯЦИЯ fr_max внутри типа (legacy, используется
        % только когда onion_skin = false)
        % Формула: fr_max,i = fr_max,type * (1.0 - modulation_pct * norm_size_in_type)
        % где norm_size_in_type ∈ [0..1] внутри данного типа
        
        % Получаем процент модуляции из конфига (по умолчанию 30%)
        if isfield(cfg.motor_units, 'fr_max_modulation_pct')
            modulation_pct = cfg.motor_units.fr_max_modulation_pct / 100;
        else
            modulation_pct = 0.30;  % 30% по умолчанию
        end
        
        same_type_indices = find([temp_mu.type_index] == mu_type_idx);
        if ~isempty(same_type_indices)
            same_type_sizes = [temp_mu(same_type_indices).size];
            if max(same_type_sizes) > min(same_type_sizes)
                norm_size = (temp_mu(i).size - min(same_type_sizes)) / (max(same_type_sizes) - min(same_type_sizes));
            else
                norm_size = 0.5;
            end
            % Уменьшаем fr_max на modulation_pct для самых больших ДЕ в типе
            temp_mu(i).fr_max = temp_mu(i).fr_max * (1.0 - modulation_pct * norm_size);
        end
    end
    
    % ========== ШАГ 2: SIZE PRINCIPLE - сортируем по размеру ==========
    sizes = [temp_mu.size];
    [~, sort_idx] = sort(sizes);  % от малых к большим
    
    % ========== ШАГ 3: Назначаем пороги рекрутирования по рангу ==========
    % ИСПРАВЛЕНО: Экспоненциальное распределение порогов по Fuglevand (1993)
    % R_i = exp(ln(R_max) * (i-1)/(N-1))
    % где R_1 = 1 (первая ДЕ), R_N = R_max (последняя ДЕ)
    
    thr_range = cfg.motor_units.recruitment_threshold_range;
    thr_min = thr_range(1);
    thr_max = thr_range(2);
    
    % R_max - отношение максимального порога к минимальному (обычно 10-30)
    R_max = thr_max / thr_min;
    
    for rank = 1:n_mu
        i = sort_idx(rank);  % индекс MU с данным рангом
        
        % Нормализованный ранг 0..1
        norm_rank = (rank - 1) / max(n_mu - 1, 1);
        
        % ЭКСПОНЕНЦИАЛЬНЫЙ порог (Fuglevand, 1993):
        % R_i = R_1 * exp(ln(R_max) * norm_rank)
        % Это даёт: малые ДЕ → низкие пороги, большие ДЕ → экспоненциально высокие
        temp_mu(i).recruitment_threshold = thr_min * exp(log(R_max) * norm_rank);
        temp_mu(i).recruitment_rank = rank;
    end
    
    % ========== ШАГ 3.5: Firing rate с учётом onion skin (Fuglevand 1993) ==========
    % ПАТЧ 5: Onion skin principle — PFR убывает с порогом рекрутирования.
    %
    % Fuglevand (1993):
    %   MFR (minimum firing rate) — единая для всех MU
    %   PFR_i = PFR_1 - PFRD * (RTE_i - RTE_1) / (RTE_n - RTE_1)
    % где PFR_1 — PFR первой (самой маленькой) MU, PFRD — диапазон PFR,
    % RTE_i — порог рекрутирования i-й MU.
    %
    % При onion_skin = false сохраняется legacy поведение (типо-зависимые FR).
    
    use_onion_skin = false;  % По умолчанию ВЫКЛЮЧЕН для обратной совместимости
    if isfield(cfg.motor_units, 'onion_skin')
        use_onion_skin = cfg.motor_units.onion_skin;
    end
    
    if use_onion_skin
        % Параметры модели Fuglevand
        % MFR — единая минимальная частота для всех MU (Гц)
        mfr_uniform = 8.0;
        if isfield(cfg.motor_units, 'onion_skin_mfr')
            mfr_uniform = cfg.motor_units.onion_skin_mfr;
        end
        
        % PFR первой (наименьшей) MU — максимальная пиковая частота
        pfr_first = 35.0;  % Гц
        if isfield(cfg.motor_units, 'onion_skin_pfr_first')
            pfr_first = cfg.motor_units.onion_skin_pfr_first;
        end
        
        % PFRD — диапазон уменьшения PFR от первой до последней MU
        % PFR_last = PFR_first - PFRD
        pfrd = 20.0;  % Гц (типично 10–30 Гц)
        if isfield(cfg.motor_units, 'onion_skin_pfrd')
            pfrd = cfg.motor_units.onion_skin_pfrd;
        end
        
        % Собираем пороги для нормализации
        all_thresholds = [temp_mu.recruitment_threshold];
        thr_min_actual = min(all_thresholds);
        thr_max_actual = max(all_thresholds);
        thr_range_actual = max(thr_max_actual - thr_min_actual, 1e-6);
        
        for i = 1:n_mu
            % Нормализованный порог [0..1]
            norm_thr = (temp_mu(i).recruitment_threshold - thr_min_actual) / thr_range_actual;
            
            % Onion skin: PFR убывает линейно с порогом
            % PFR_i = PFR_first - PFRD * norm_threshold
            temp_mu(i).fr_min = mfr_uniform;
            temp_mu(i).fr_max = max(pfr_first - pfrd * norm_thr, mfr_uniform + 2.0);
        end
    end
    
    % Пересчёт fr_gain с учётом порогов рекрутирования
    % КРИТИЧНО: fr_gain должен обеспечить правильную линейную модуляцию между fr_min и fr_max
    % Формула по Fuglevand:
    % fr_i(u) = fr_min + (fr_max,i - fr_min) * (u - R_i) / (1 - R_i)
    % => fr_gain = (fr_max,i - fr_min) / (1 - R_i)
    
    for i = 1:n_mu
        threshold_norm = temp_mu(i).recruitment_threshold;
        % Защита от деления на 0 и численной неустойчивости
        denom = max(1.0 - threshold_norm, 0.01);
        temp_mu(i).fr_gain = (temp_mu(i).fr_max - temp_mu(i).fr_min) / denom;
    end
    
    % ========== ШАГ 4: Создаём финальный mu_pool с позициями и волокнами ==========
    mu_pool = struct();
    territory_std = sqrt(muscle_cfg.cross_section_area / n_mu) * 2;
    % FIX Bug 1: Ограничиваем territory_std радиусом мышцы
    % При n_mu=1 без этого territory_std = sqrt(area)*2 >> muscle_radius,
    % и волокна разбрасываются далеко за пределы мышцы
    territory_std = min(territory_std, muscle_radius * 0.4);
    
    % ПАТЧ 10: Эллиптические территории (Petersen 2019)
    % Для плоских мышц (FDS, abductor pollicis brevis и т.п.) территории MU
    % должны быть эллиптическими, вытянутыми вдоль оси мышцы.
    % aspect_ratio > 1: вытянуты вдоль длинной оси мышцы.
    use_elliptical = false;
    territory_aspect = 1.0;  % Круговое по умолчанию
    territory_angle_rad = 0;  % Ориентация эллипса (рад)
    
    if isfield(cfg.motor_units, 'territory_elliptical') && cfg.motor_units.territory_elliptical
        use_elliptical = true;
        
        % Aspect ratio (отношение длинной к короткой оси)
        if isfield(cfg.motor_units, 'territory_aspect_ratio')
            territory_aspect = max(1.0, cfg.motor_units.territory_aspect_ratio);
        else
            % Авто: вычисляем из полигона мышцы или используем 2.0 по умолчанию
            if has_polygon
                % PCA на полигоне для определения главных осей
                poly_centered = poly_pts - mean(poly_pts, 1);
                [~, S, ~] = svd(poly_centered, 'econ');
                if size(S, 2) >= 2
                    territory_aspect = max(S(1,1) / max(S(2,2), 1e-6), 1.0);
                    territory_aspect = min(territory_aspect, 5.0);  % Ограничение
                else
                    territory_aspect = 2.0;
                end
            else
                territory_aspect = 2.0;  % Типичное для предплечья
            end
        end
        
        % Ориентация эллипса
        if isfield(cfg.motor_units, 'territory_angle_deg')
            territory_angle_rad = cfg.motor_units.territory_angle_deg * pi / 180;
        else
            % Авто: ориентация по длинной оси полигона
            if has_polygon
                poly_centered = poly_pts - mean(poly_pts, 1);
                [~, ~, V] = svd(poly_centered, 'econ');
                territory_angle_rad = atan2(V(2,1), V(1,1));
            end
        end
    end
    
    for i = 1:n_mu
        % Копируем базовые параметры
        mu_pool(i).type = temp_mu(i).type;
        mu_pool(i).type_index = temp_mu(i).type_index;
        mu_pool(i).cv = temp_mu(i).cv;
        mu_pool(i).twitch_amplitude = temp_mu(i).twitch_amplitude;
        mu_pool(i).twitch_rise_time = temp_mu(i).twitch_rise_time;
        mu_pool(i).twitch_fall_time = temp_mu(i).twitch_fall_time;
        mu_pool(i).recruitment_threshold = temp_mu(i).recruitment_threshold;
        mu_pool(i).recruitment_rank = temp_mu(i).recruitment_rank;
        mu_pool(i).size = temp_mu(i).size;
        mu_pool(i).fr_min = temp_mu(i).fr_min;
        mu_pool(i).fr_max = temp_mu(i).fr_max;
        mu_pool(i).fr_gain = temp_mu(i).fr_gain;
        mu_pool(i).n_fibers = temp_mu(i).n_fibers;
        
        % Генерация territory_center
        if has_pregenerated_positions
            pos_idx = min(i, size(muscle_cfg.mu_positions, 1));
            territory_xy = muscle_cfg.mu_positions(pos_idx, :)';
            territory_z = geom.length * (0.3 + 0.4 * (i / n_mu));
            territory_center = [territory_xy; territory_z];
            
            if point_in_any_bone(territory_xy, geom.bones)
                territory_center = move_point_from_bones(territory_center, geom.bones);
            end
        else
            max_attempts = 50;
            valid_center = false;
            
            for attempt = 1:max_attempts
                if has_polygon
                    px = poly_min_x + rand() * (poly_max_x - poly_min_x);
                    py = poly_min_y + rand() * (poly_max_y - poly_min_y);
                    if inpolygon(px, py, poly_pts(:,1), poly_pts(:,2))
                        territory_xy = [px; py];
                    else
                        continue;
                    end
                else
                    r_norm = sqrt(rand()) * muscle_radius * 0.9;
                    theta = rand() * 2 * pi;
                    territory_xy = muscle_center_xy + r_norm * [cos(theta); sin(theta)];
                end
                
                territory_z = geom.length * (0.3 + 0.4*rand());
                territory_center = [territory_xy; territory_z];
                
                if ~point_in_any_bone(territory_xy, geom.bones)
                    valid_center = true;
                    break;
                end
            end
            
            if ~valid_center
                territory_center = move_point_from_bones(territory_center, geom.bones);
            end
        end
        
        mu_pool(i).territory_center = territory_center;
        mu_pool(i).territory_std = territory_std;
        % ПАТЧ 10: Эллиптические параметры территории
        mu_pool(i).territory_aspect = territory_aspect;
        mu_pool(i).territory_angle = territory_angle_rad;
        mu_pool(i).territory_elliptical = use_elliptical;
        
        % Генерируем репрезентативные волокна с весом масштабирования
        n_representative = min(30, mu_pool(i).n_fibers);
        mu_pool(i).fiber_weight = mu_pool(i).n_fibers / n_representative;  % Вес для масштабирования
        mu_pool(i).fibers = generate_muscle_fibers(mu_pool(i), muscle_cfg, geom, n_representative);
    end
    
    % Восстанавливаем генератор случайных чисел
    if ~has_pregenerated_positions
        rng('shuffle');
    end
end

%--------------------------------------------------------------------------
% MODULE: Fiber generation inside a MU
%
% Purpose:
%   - Генерирует набор мышечных волокон, принадлежащих одному MU,
%     в пределах поперечного сечения мышцы с учётом ограничений (кости).
%
% Output:
%   fibers : struct/array с геометрией волокон (точки/направления/длины)
%
% Notes:
%   Количество волокон может задаваться косвенно через площадь MU или явным параметром.
%--------------------------------------------------------------------------
function fibers = generate_muscle_fibers(mu, muscle_cfg, geom, n_fibers)

    fibers = struct();
    territory_center = mu.territory_center;
    territory_std = mu.territory_std;
    
    % ПАТЧ 10: Эллиптические территории
    use_elliptical = isfield(mu, 'territory_elliptical') && mu.territory_elliptical;
    if use_elliptical
        aspect = mu.territory_aspect;
        theta_ell = mu.territory_angle;
        % Стандартные отклонения вдоль главных осей эллипса:
        % Площадь эллипса = π·a·b, где a = std_major, b = std_minor
        % При сохранении той же площади: a = std * sqrt(aspect), b = std / sqrt(aspect)
        std_major = territory_std * sqrt(aspect);
        std_minor = territory_std / sqrt(aspect);
        % Матрица поворота для 2D
        R_ell = [cos(theta_ell), -sin(theta_ell); sin(theta_ell), cos(theta_ell)];
    end
    
    % Получаем информацию о костях для проверки
    bones = geom.bones;
    
    % FIX Bug 1: Получаем границы мышцы для проверки
    angle = muscle_cfg.position_angle * pi/180;
    depth = muscle_cfg.depth;
    muscle_center_xy = [depth * cos(angle); depth * sin(angle)];
    muscle_radius = sqrt(muscle_cfg.cross_section_area / pi);
    has_polygon = isfield(muscle_cfg, 'polygon') && ~isempty(muscle_cfg.polygon) && size(muscle_cfg.polygon, 1) >= 3;
    if has_polygon
        poly_pts = muscle_cfg.polygon + muscle_center_xy';
    end
    
    for f = 1:n_fibers
        max_attempts = 50;
        valid_pos = false;
        
        for attempt = 1:max_attempts
            if use_elliptical
                % ПАТЧ 10: Эллиптическое распределение волокон
                % Генерируем в локальной СК эллипса, потом поворачиваем
                dxy_local = [std_major * randn(); std_minor * randn()];
                dxy_global = R_ell * dxy_local;
                fiber_pos = territory_center + [dxy_global; territory_std*0.5*randn()];
            else
                fiber_pos = territory_center + randn(3, 1) .* [territory_std; territory_std; territory_std*0.5];
            end
            
            % Проверяем, что волокно не в кости
            if point_in_any_bone(fiber_pos(1:2), bones)
                continue;
            end
            
            % FIX Bug 1: Проверяем, что волокно ВНУТРИ мышцы
            if has_polygon
                if ~inpolygon(fiber_pos(1), fiber_pos(2), poly_pts(:,1), poly_pts(:,2))
                    continue;  % Вне полигона мышцы
                end
            else
                dist_from_center = norm(fiber_pos(1:2) - muscle_center_xy);
                if dist_from_center > muscle_radius * 0.95
                    continue;  % Вне эллипса/круга мышцы (с 5% зазором)
                end
            end
            
            valid_pos = true;
            break;
        end
        
        % Если не нашли валидную позицию, проецируем на мышцу
        if ~valid_pos
            % Проецируем на ближайшую точку внутри мышцы
            dir_from_center = fiber_pos(1:2) - muscle_center_xy;
            dist_from_center = norm(dir_from_center);
            if dist_from_center > muscle_radius * 0.9
                if dist_from_center > 1e-6
                    fiber_pos(1:2) = muscle_center_xy + dir_from_center / dist_from_center * muscle_radius * 0.8;
                else
                    fiber_pos(1:2) = muscle_center_xy;
                end
            end
            fiber_pos = move_point_from_bones(fiber_pos, bones);
        end
        
        fiber_length = muscle_cfg.fiber_length * (0.8 + 0.4*rand());
        nmj_position = 0.3 + 0.4*rand();
        
        fibers(f).position = fiber_pos;
        fibers(f).length = fiber_length;
        fibers(f).nmj_position = nmj_position;
        fibers(f).direction = [0; 0; 1];
        
        n_segments = ceil(fiber_length / 0.001);
        fibers(f).segments = linspace(-fiber_length*nmj_position, fiber_length*(1-nmj_position), n_segments);
    end
end

%--------------------------------------------------------------------------
% GEOMETRY HELPER: test if point lies inside any bone cross-section
%--------------------------------------------------------------------------
function in_bone = point_in_any_bone(xy, bones)
    % Проверяет, находится ли точка xy внутри любой кости
    % xy - вектор [x; y] или [x, y]
    % bones - структура с полями positions и radii
    in_bone = false;
    
    if isempty(bones) || ~isfield(bones, 'positions')
        return;
    end
    
    x = xy(1);
    y = xy(2);
    
    for b = 1:size(bones.positions, 1)
        bx = bones.positions(b, 1);
        by = bones.positions(b, 2);
        br = bones.radii(b);
        
        dist = sqrt((x - bx)^2 + (y - by)^2);
        if dist < br + 0.001  % 1мм зазор
            in_bone = true;
            return;
        end
    end
end

%--------------------------------------------------------------------------
% GEOMETRY HELPER: push a point out of bone regions (simple repulsion)
% Purpose:
%   - Используется для гарантии, что MU/волокна не "попали" внутрь кости.
%--------------------------------------------------------------------------
function new_pos = move_point_from_bones(pos, bones)
    % Сдвигает точку от ближайшей кости
    new_pos = pos;
    
    if isempty(bones) || ~isfield(bones, 'positions')
        return;
    end
    
    x = pos(1);
    y = pos(2);
    
    % Находим ближайшую кость
    min_penetration = inf;
    closest_bone = 0;
    
    for b = 1:size(bones.positions, 1)
        bx = bones.positions(b, 1);
        by = bones.positions(b, 2);
        br = bones.radii(b);
        
        dist = sqrt((x - bx)^2 + (y - by)^2);
        penetration = br + 0.002 - dist;  % 2мм зазор
        
        if penetration > 0 && dist < min_penetration
            min_penetration = dist;
            closest_bone = b;
        end
    end
    
    if closest_bone > 0
        bx = bones.positions(closest_bone, 1);
        by = bones.positions(closest_bone, 2);
        br = bones.radii(closest_bone);
        
        % Вектор от центра кости к точке
        dx = x - bx;
        dy = y - by;
        d = sqrt(dx^2 + dy^2);
        
        if d < 1e-6
            % Точка в центре кости - сдвигаем в случайном направлении
            angle = rand() * 2 * pi;
            dx = cos(angle);
            dy = sin(angle);
            d = 1;
        end
        
        % Новая позиция за пределами кости с зазором
        new_dist = br + 0.003;  % 3мм от поверхности кости
        new_pos(1) = bx + dx/d * new_dist;
        new_pos(2) = by + dy/d * new_dist;
    end
end

%--------------------------------------------------------------------------
% MODULE: Target force profile generator (F_ref(t))
%
% Purpose:
%   - Возвращает целевую силу для мышцы в момент времени t.
%   - Профиль задаётся в muscle_cfg (тип профиля + параметры).
%
% Output:
%   F_ref : целевая сила (обычно нормированная 0..1 или в Н — зависит от cfg)
%
% Notes:
%   Важно: единицы F_ref должны быть согласованы с контроллером и F_max.
%--------------------------------------------------------------------------
function F_ref = compute_reference_force(t, muscle_cfg)

    profile = muscle_cfg.force_profile;
    
    if isfield(profile, 'custom_data') && ~isempty(profile.custom_data)
        F_ref = interp1(profile.custom_data(:, 1), profile.custom_data(:, 2), t, 'linear', 0);
        return;
    end
    
    F_max = profile.F_max;
    
    switch profile.type
        case 'ramp_hold'
            ramp_t = profile.ramp_time;
            hold_t = profile.hold_time;
            % FIX: decay_tau пропорционален ramp_time (а не жёсткие 1.0 с)
            % Если задан ramp_down_time, используем его; иначе tau = ramp_time
            if isfield(profile, 'ramp_down_time') && profile.ramp_down_time > 0
                decay_tau = profile.ramp_down_time / 3.0;  % ~95% спад за ramp_down_time
            else
                decay_tau = max(ramp_t, 0.05);  % Не менее 50 мс для стабильности
            end
            if t < ramp_t, F_ref = F_max * (t / ramp_t);
            elseif t < ramp_t + hold_t, F_ref = F_max;
            else, F_ref = F_max * exp(-(t - ramp_t - hold_t) / decay_tau);
            end
            % Отсекаем малые значения чтобы контроллер не "гонял" остаточную силу
            if F_ref < F_max * 0.01, F_ref = 0; end
        case 'sine'
            F_ref = F_max * (0.5 + 0.5*sin(2*pi*profile.frequency*t));
        case 'trapezoid'
            ramp_up = profile.ramp_time;
            hold_t = profile.hold_time;
            ramp_down = profile.ramp_down_time;
            if t < ramp_up, F_ref = F_max * (t / ramp_up);
            elseif t < ramp_up + hold_t, F_ref = F_max;
            elseif t < ramp_up + hold_t + ramp_down, F_ref = F_max * (1 - (t - ramp_up - hold_t) / ramp_down);
            else, F_ref = 0;
            end
        case 'constant', F_ref = F_max;
        case 'step'
            if t >= profile.step_time, F_ref = F_max; else, F_ref = 0; end
        case 'pulse'
            % Одиночный прямоугольный импульс: подъём в pulse_start, спад в pulse_start + pulse_duration
            pulse_start = 0;
            if isfield(profile, 'step_time'), pulse_start = profile.step_time;
            elseif isfield(profile, 'pulse_start'), pulse_start = profile.pulse_start; end
            pulse_dur = 0.1;  % 100 мс по умолчанию
            if isfield(profile, 'pulse_duration'), pulse_dur = profile.pulse_duration; end
            if t >= pulse_start && t < pulse_start + pulse_dur
                F_ref = F_max;
            else
                F_ref = 0;
            end
        otherwise, F_ref = 0;
    end
end

function [u, e_integral, prev_error, prev_de_dt_f] = compute_neural_drive_per_muscle(F_ref, F_current, e_integral, prev_error, prev_de_dt_f, lut, cfg)
% compute_neural_drive_per_muscle - Контроллер силы мышцы (v2: PID + predictive FF)
%
% Архитектура:
%   u = u_ff_predictive(F_ref) + Kp * e_norm + Ki * integral(e_norm) + Kd * de/dt
%
% Изменения относительно v1:
%   1) Model-predictive feedforward: учитывает tau_decay при расчёте drive
%   2) D-составляющая для упреждения динамики (демпфирование overshoot)
%   3) Back-calculation anti-windup (пропорциональный сброс интегратора)
%   4) Сниженный Ki для уменьшения интегрального перерегулирования
%
% ВХОД:
%   F_ref      : целевая сила (Н)
%   F_current  : текущая сила мышцы (Н)
%   e_integral : состояние интегратора
%   prev_error : предыдущая ошибка (для D-составляющей)
%   lut        : struct с полями .drive, .force, .F_max_actual
%   cfg        : конфигурация

    dt = 1 / cfg.simulation.fs_internal;

    F_max_actual = max(lut.F_max_actual, 1e-6);
    
    % === FEEDFORWARD: drive = F_inverse(F_ref) из LUT ===
    F_ref_clamped = max(0, min(F_ref, F_max_actual));
    if F_ref_clamped <= 0
        u_ff = 0;
    elseif F_ref_clamped >= F_max_actual * 0.999
        u_ff = 1;
    else
        [F_unique, idx_unique] = unique(lut.force, 'last');
        D_unique = lut.drive(idx_unique);
        
        if length(F_unique) >= 2 && F_ref_clamped >= min(F_unique) && F_ref_clamped <= max(F_unique)
            u_ff = interp1(F_unique, D_unique, F_ref_clamped, 'linear');
        else
            if F_ref_clamped < min(F_unique)
                if min(F_unique) > 0
                    u_ff = D_unique(1) * (F_ref_clamped / min(F_unique));
                else
                    u_ff = 0;
                end
            else
                u_ff = D_unique(end) + (F_ref_clamped - F_unique(end)) / (F_max_actual - F_unique(end)) * (1 - D_unique(end));
            end
        end
        u_ff = max(0, min(1, u_ff));
    end

    % === MODEL-PREDICTIVE FEEDFORWARD КОРРЕКЦИЯ ===
    % Учитываем инерцию мышцы: компенсируем tau_decay активации
    if isfield(cfg.motor_units, 'force_dynamics') && cfg.motor_units.force_dynamics.enabled
        fd = cfg.motor_units.force_dynamics;
        tau_avg = mean(fd.tau_decay);
        
        % Предиктивная коррекция пропорциональна ошибке и tau
        e_force = F_ref - F_current;
        predictive_boost = tau_avg * (e_force / max(F_max_actual, 1)) * 1.0;
        predictive_boost = max(-0.10, min(0.10, predictive_boost));
        u_ff = max(0, min(1, u_ff + predictive_boost));
    end

    % === PID-КОРРЕКЦИЯ в нормализованном пространстве [0..1] ===
    e_norm = (F_ref - F_current) / F_max_actual;

    % Коэффициенты PID-контроллера
    if isfield(cfg.motor_units, 'force_controller_Kp')
        Kp = cfg.motor_units.force_controller_Kp;
    else
        Kp = 6.0;     % FIX: снижен с 8.0
    end
    
    if isfield(cfg.motor_units, 'force_controller_Ki')
        Ki = cfg.motor_units.force_controller_Ki;
    else
        Ki = 4.0;     % FIX: снижен с 12.0 (главная причина перерегулирования)
    end
    
    if isfield(cfg.motor_units, 'force_controller_Kd')
        Kd = cfg.motor_units.force_controller_Kd;
    else
        Kd = 1.5;     % FIX: D-составляющая для демпфирования
    end
    
    % НЕЛИНЕЙНАЯ КОРРЕКЦИЯ Kp для малых drive
    if u_ff < 0.3
        Kp_effective = Kp * (1.0 + 0.5*(0.3 - u_ff)/0.3);
    else
        Kp_effective = Kp;
    end

    % === D-СОСТАВЛЯЮЩАЯ (реальный LPF на производной ошибки) ===
    de_dt = (e_norm - prev_error) / dt;

    % 1-полюсный НЧ-фильтр производной (с памятью!)
    if isfield(cfg.motor_units, 'force_controller_d_lpf_hz')
        d_lpf_hz = cfg.motor_units.force_controller_d_lpf_hz;
    else
        d_lpf_hz = 50;  % Гц
    end
    alpha_d = exp(-2*pi*d_lpf_hz*dt);
    de_dt_f = alpha_d * prev_de_dt_f + (1 - alpha_d) * de_dt;

    prev_de_dt_f = de_dt_f;
    prev_error = e_norm;

    % === ИНТЕГРАТОР: conditional integration + clamp + sign-reversal drain ===
    if isfield(cfg.motor_units, 'force_controller_I_lim')
        I_lim = cfg.motor_units.force_controller_I_lim;
    else
        I_lim = 0.5;  % лимит интегратора в нормализованном пространстве
    end

    % Выход без интегратора (для расчёта насыщения)
    u_no_int = u_ff + Kp_effective * e_norm + Kd * de_dt_f;
    u_pre = u_no_int + Ki * e_integral;
    u_sat = max(0, min(1, u_pre));

    % FIX: Если ошибка и интегратор имеют РАЗНЫЕ знаки — интегратор "застрял"
    % Агрессивно дренируем его в этом случае (back-calculation anti-windup)
    if sign(e_norm) ~= sign(e_integral) && abs(e_integral) > 1e-6
        % Коэффициент дренажа: чем больше рассогласование, тем быстрее сбрасываем
        drain_rate = 10.0;  % 1/с — полный сброс за ~0.1 с
        e_integral = e_integral * exp(-drain_rate * dt);
    end

    % Интегрируем только если это не усиливает насыщение
    integrate_ok = true;
    if (u_sat >= 1 && e_norm > 0), integrate_ok = false; end
    if (u_sat <= 0 && e_norm < 0), integrate_ok = false; end

    if integrate_ok
        e_integral = e_integral + e_norm * dt;
        % clamp интегратора
        e_integral = max(-I_lim, min(I_lim, e_integral));
        % пересчитать u с обновлённым интегратором
        u = max(0, min(1, u_no_int + Ki * e_integral));
    else
        % не трогаем интегратор, чтобы не "залипать" в saturation
        u = u_sat;
    end
end



%--------------------------------------------------------------------------
% MODULE: MU spike generation at a single time step
%
% Purpose:
%   - По neural_drive определяет рекрутирование MU (по thresholds).
%   - Преобразует drive в firing rate (min..max) и генерирует спайк (Bernoulli/ISI).
%   - Учитывает last_spike_times для рефрактерности/ISI-джиттера.
%
% Output:
%   spikes       : logical [n_MU x 1] (true если MU выстрелил в момент t)
%   firing_rates : оценка частот разряда (Гц) для диагностики/отладки
%--------------------------------------------------------------------------
function [spikes, firing_rates] = generate_spikes_at_time(mu_pool, neural_drive, t, last_spike_times, cfg)
    n_mu = length(mu_pool);
    spikes = false(n_mu, 1);
    firing_rates = zeros(n_mu, 1);
    
    for i = 1:n_mu
        mu = mu_pool(i);
        if neural_drive < mu.recruitment_threshold, continue; end
        
        drive_above_threshold = neural_drive - mu.recruitment_threshold;
        fr_target = min(mu.fr_min + mu.fr_gain * drive_above_threshold, mu.fr_max);
        firing_rates(i) = fr_target;
        
        time_since_last = t - last_spike_times(i);
        refractory_period = 0.003;
        if time_since_last < refractory_period, continue; end
        
        isi_target = 1 / fr_target;
        isi_std = isi_target * cfg.motor_units.isi_cv;
        isi_threshold = max(refractory_period, isi_target + randn() * isi_std);
        
        if time_since_last >= isi_threshold, spikes(i) = true; end
    end
end

%--------------------------------------------------------------------------
% MODULE: MU spike generation V2 - с common drive и gamma renewal (ПАТЧ 1)
%
% Purpose:
%   - Модулирует neural_drive общей компонентой (common drive) для корреляций между MU
%   - Использует gamma renewal process для реалистичной статистики ISI
%   - Учитывает рефрактерность и модулирует частоту через rate coding
%
% Inputs:
%   mu_pool      : массив MU с параметрами
%   neural_drive : базовый нейронный драйв (0..1)
%   t            : текущее время (с)
%   state        : состояние мышцы (включая next_spike_times, indep_noise)
%   cd_state     : состояние common drive (value, alpha, indep_alpha)
%   cfg          : конфигурация
%
% Outputs:
%   spikes : logical [n_MU x 1]
%   state  : обновлённое состояние
%--------------------------------------------------------------------------
function [spikes, state] = generate_spikes_at_time_v2(mu_pool, neural_drive, t, state, cd_state, cfg)
    n_mu = length(mu_pool);
    spikes = false(n_mu, 1);
    dt = 1 / cfg.simulation.fs_internal;
    
    % Параметры common drive
    cd_enabled = isfield(cfg.motor_units, 'common_drive') && cfg.motor_units.common_drive.enabled;
    if cd_enabled
        cd_cfg = cfg.motor_units.common_drive;
        common_strength = cd_cfg.strength;
        indep_strength = cd_cfg.indep_strength;
        sync_prob = cd_cfg.sync_prob;
    else
        common_strength = 0;
        indep_strength = 0;
        sync_prob = 0;
    end
    
    % Параметры рефрактерности
    if isfield(cfg.motor_units, 'refractory_s')
        refractory_s = cfg.motor_units.refractory_s;
    else
        refractory_s = 0.003;
    end
    
    % CV для gamma distribution (shape = 1/CV^2)
    isi_cv = cfg.motor_units.isi_cv;
    gamma_shape = max(1.0, 1 / (isi_cv^2));  % k = 1/CV^2
    
    % Модель спайков
    use_gamma = isfield(cfg.motor_units, 'spike_model') && ...
                strcmp(cfg.motor_units.spike_model, 'gamma_renewal');
    
    for i = 1:n_mu
        mu = mu_pool(i);
        
        % Обновление независимого шума для этого MU (AR(1) фильтр)
        if cd_enabled && indep_strength > 0
            state.indep_noise(i) = cd_state.indep_alpha * state.indep_noise(i) + ...
                sqrt(1 - cd_state.indep_alpha^2) * randn();
        end
        
        % Эффективный драйв с common drive и независимым шумом
        if cd_enabled
            % ПАТЧ 6: Выбор режима common drive
            % 'multiplicative' (legacy): u_eff = u * (1 + cd + noise)
            %   — амплитуда шума пропорциональна drive, при малых drive шум исчезает
            % 'additive' (Fuglevand, De Luca): u_eff = u + cd_strength * cd + indep * noise
            %   — физиологически более корректно: шум не зависит от уровня drive
            cd_mode = 'multiplicative';  % По умолчанию мультипликативный (legacy, обратная совместимость)
            if isfield(cd_cfg, 'mode')
                cd_mode = cd_cfg.mode;
            end
            
            if strcmp(cd_mode, 'multiplicative')
                % Legacy мультипликативный режим
                u_eff = neural_drive * (1 + common_strength * cd_state.value + ...
                    indep_strength * state.indep_noise(i));
            else
                % Аддитивный режим (Fuglevand, De Luca)
                u_eff = neural_drive + common_strength * cd_state.value + ...
                    indep_strength * state.indep_noise(i);
            end
            u_eff = max(0, min(1, u_eff));  % Ограничение 0..1
        else
            u_eff = neural_drive;
        end
        
        % Проверка рекрутирования
        if u_eff < mu.recruitment_threshold
            % MU дерекрутирован - сбрасываем время следующего спайка
            state.next_spike_times(i) = inf;
            continue;
        end
        
        % Вычисление целевой частоты разрядов
        drive_above_threshold = u_eff - mu.recruitment_threshold;
        fr_target = min(mu.fr_min + mu.fr_gain * drive_above_threshold, mu.fr_max);
        
        % Проверка рефрактерного периода
        time_since_last = t - state.last_spike_times(i);
        if time_since_last < refractory_s
            continue;
        end
        
        if use_gamma
            % === GAMMA RENEWAL PROCESS ===
            % Ключевой патч: при рекрутировании (next_spike_times=inf) генерируем первый спайк сразу,
            % иначе появляется искусственная задержка ~ISI (≈0.1 c при fr_min 8–10 Гц).

            is_newly_recruited = isinf(state.next_spike_times(i));

            if is_newly_recruited
                % Первый спайк "на входе" в рекрутирование (можно сделать t+refractory, но так проще и быстро)
                spikes(i) = true;
                state.last_spike_times(i) = t;

                % Сгенерировать следующий ISI
                mean_isi = 1 / max(fr_target, 1);
                gamma_scale = mean_isi / gamma_shape;

                try
                    next_isi = gamrnd(gamma_shape, gamma_scale);
                catch
                    next_isi = sum(-gamma_scale * log(rand(ceil(gamma_shape), 1)));
                end

                next_isi = max(next_isi, refractory_s);

                if sync_prob > 0 && rand() < sync_prob
                    next_isi = next_isi + (rand() - 0.5) * 0.002;
                    next_isi = max(next_isi, refractory_s);
                end

                state.next_spike_times(i) = t + next_isi;

            else
                % Обычный режим: спайк, когда пришло время
                if t >= state.next_spike_times(i)
                    spikes(i) = true;
                    % ПАТЧ 4: Сохраняем истинное (непрерывное) время спайка,
                    % а не квантованное на сетку t. Это устраняет спектральные
                    % артефакты от привязки spike times к кратным dt (Petersen 2019).
                    state.last_spike_times(i) = state.next_spike_times(i);

                    mean_isi = 1 / max(fr_target, 1);
                    gamma_scale = mean_isi / gamma_shape;

                    try
                        next_isi = gamrnd(gamma_shape, gamma_scale);
                    catch
                        next_isi = sum(-gamma_scale * log(rand(ceil(gamma_shape), 1)));
                    end

                    next_isi = max(next_isi, refractory_s);

                    if sync_prob > 0 && rand() < sync_prob
                        next_isi = next_isi + (rand() - 0.5) * 0.002;
                        next_isi = max(next_isi, refractory_s);
                    end

                    state.next_spike_times(i) = t + next_isi;
                end
            end
        end

    end
end

%--------------------------------------------------------------------------
% MODULE: Twitch summation -> muscle force
%
% Purpose:
%   - Обновляет список активных twitch-ответов от спайков.
%   - Суммирует вклад twitch-ов, получая текущую силу мышцы state.force.
%
% Notes:
%   Этот блок определяет динамику "сила ↔ спайки". Он должен быть численно устойчивым.
%--------------------------------------------------------------------------
function state = compute_muscle_force(spikes, mu_pool, state, t, ~)

    for i = 1:length(mu_pool)
        if spikes(i)
            mu = mu_pool(i);
            new_twitch = struct('mu_idx', i, 'start_time', t, 'amplitude', mu.twitch_amplitude, ...
                'rise_time', mu.twitch_rise_time, 'fall_time', mu.twitch_fall_time);
            if isempty(state.twitch_history), state.twitch_history = new_twitch;
            else, state.twitch_history(end+1) = new_twitch;
            end
        end
    end
    
    F = 0;
    if isempty(state.twitch_history), state.force = F; return; end
    
    max_twitch_duration = 0.3;
    active_twitches = [];
    
    for i = 1:length(state.twitch_history)
        tw = state.twitch_history(i);
        time_since_start = t - tw.start_time;
        if time_since_start < 0, continue; end
        
        if time_since_start < max_twitch_duration
            active_twitches(end+1) = i;
            if time_since_start < tw.rise_time
                f_tw = tw.amplitude * (1 - exp(-3 * time_since_start / tw.rise_time));
            else
                f_tw = tw.amplitude * exp(-3 * (time_since_start - tw.rise_time) / tw.fall_time);
            end
            if isnan(f_tw) || isinf(f_tw), f_tw = 0; end
            F = F + f_tw;
        end
    end
    
    if ~isempty(active_twitches), state.twitch_history = state.twitch_history(active_twitches);
    else, state.twitch_history = struct([]);
    end
    state.force = F;
end

%--------------------------------------------------------------------------
% MODULE: Muscle force V2 - с активационной динамикой и утомлением (ПАТЧ 2)
%
% Purpose:
%   - Вычисляет силу мышцы через состояние активации a_i(t) для каждого MU
%   - Использует нелинейную тетаническую суммирующую функцию (Hill-type)
%   - Опционально учитывает утомление
%
% Inputs:
%   spikes   : logical [n_MU x 1] - спайки на текущем шаге
%   mu_pool  : массив MU с параметрами
%   state    : состояние мышцы (включая activation, fatigue)
%   t        : текущее время
%   cfg      : конфигурация
%
% Output:
%   state : обновлённое состояние с новой силой
%--------------------------------------------------------------------------
function state = compute_muscle_force_v2(spikes, mu_pool, state, t, cfg)
    n_mu = length(mu_pool);
    dt = 1 / cfg.simulation.fs_internal;

    % Проверяем, включена ли новая модель силы
    use_new_dynamics = isfield(cfg.motor_units, 'force_dynamics') && ...
                       cfg.motor_units.force_dynamics.enabled;

    if ~use_new_dynamics
        % Используем старую модель
        state = compute_muscle_force(spikes, mu_pool, state, t, cfg);
        return;
    end

    fd_cfg = cfg.motor_units.force_dynamics;

    % -------------------- PATCH: дефолты/санити --------------------
    % spike_gain: на сколько один спайк поднимает активацию (линейно).
    % Если значение некорректное — авто-калибровка внутри функции (fallback).
    if ~isfield(fd_cfg, 'spike_gain') || ...
       (ischar(fd_cfg.spike_gain) && strcmp(fd_cfg.spike_gain, 'auto')) || ...
       (isnumeric(fd_cfg.spike_gain) && any(fd_cfg.spike_gain < 0.05))
        % Авто-калибровка: sg = 1 - exp(-1/(fr_max * tau_decay))
        if isscalar(cfg.motor_units.firing_rate_max)
            fr_mx = cfg.motor_units.firing_rate_max;
        else
            fr_mx = max(cfg.motor_units.firing_rate_max);
        end
        sg_vec = zeros(1, numel(fd_cfg.tau_decay));
        for qq = 1:numel(fd_cfg.tau_decay)
            sg_vec(qq) = 1 - exp(-1 / (fr_mx * fd_cfg.tau_decay(qq)));
        end
        fd_cfg.spike_gain = sg_vec;
    end
    if ~isfield(fd_cfg, 'hill_n'), fd_cfg.hill_n = 3; end
    if ~isfield(fd_cfg, 'a50'),    fd_cfg.a50    = 0.3; end

    % Параметры Hill-type нелинейности
    hill_n = fd_cfg.hill_n;
    a50    = fd_cfg.a50;

    % Параметры утомления
    fatigue_enabled = isfield(fd_cfg, 'fatigue_enabled') && fd_cfg.fatigue_enabled;
    if fatigue_enabled
        fatigue_rate     = fd_cfg.fatigue_rate;
        recovery_rate    = fd_cfg.recovery_rate;
        fatigue_force_k  = fd_cfg.fatigue_force_k;
        fatigue_cv_k     = fd_cfg.fatigue_cv_k; %#ok<NASGU> % (пока не используется здесь)
    end

    F_total = 0;

    for i = 1:n_mu
        mu = mu_pool(i);

        % Получаем параметры активации для типа MU
        type_idx = mu.type_index;
        if type_idx < 1 || type_idx > 3
            type_idx = 1;
        end

        % ВАЖНО: tau_rise больше не используется в логике "target=1 на один dt"
        % Мы используем интеграцию спайков + эксп. спад (см. PATCH ниже).
        tau_decay = fd_cfg.tau_decay(type_idx);

        % -------------------- PATCH A: spike-integrating activation --------------------
        % Линейная суммация спайков:
        %   1) каждый шаг: a(t+dt) = a(t) * exp(-dt/tau_decay) — экспоненциальный спад
        %   2) если спайк:  a += spike_gain                    — линейный инкремент
        %
        % Стационарное состояние: a_ss = spike_gain / (1 - exp(-ISI/tau_decay))
        %   При fr_max: spike_gain подобран так, что a_ss = 1.0 (полный тетанус)
        %   При fr_min: a_ss ≈ 0.1..0.4 (неполный тетанус → rate coding модулирует силу)
        current_activation = state.activation(i);

        % 1) экспоненциальный спад каждый шаг
        decay = exp(-dt / max(tau_decay, 1e-6));
        new_activation = current_activation * decay;

        % 2) линейный импульс от спайка
        if spikes(i)
            % spike_gain — скаляр или массив по типам MU
            if numel(fd_cfg.spike_gain) == 1
                spike_gain = fd_cfg.spike_gain;
            else
                spike_gain = fd_cfg.spike_gain(type_idx);
            end

            new_activation = new_activation + spike_gain;

            % twitch_history оставляем для обратной совместимости/валидации
            new_twitch = struct('mu_idx', i, 'start_time', t, 'amplitude', mu.twitch_amplitude, ...
                'rise_time', mu.twitch_rise_time, 'fall_time', mu.twitch_fall_time);
            if isempty(state.twitch_history)
                state.twitch_history = new_twitch;
            else
                state.twitch_history(end+1) = new_twitch;
            end
        end

        % clamp 0..1
        new_activation = max(0, min(1, new_activation));
        state.activation(i) = new_activation;
        % -------------------- END PATCH A --------------------

        % === УТОМЛЕНИЕ (опционально) ===
        if fatigue_enabled
            % Утомление растёт при высокой активации, восстанавливается при низкой
            if new_activation > 0.1
                state.fatigue(i) = min(1, state.fatigue(i) + fatigue_rate * new_activation * dt);
            else
                state.fatigue(i) = max(0, state.fatigue(i) - recovery_rate * dt);
            end

            % Модификация силы от утомления
            fatigue_factor = 1 - fatigue_force_k * state.fatigue(i);
        else
            fatigue_factor = 1.0;
        end

        % === НЕЛИНЕЙНАЯ ТЕТАНИЧЕСКАЯ ФУНКЦИЯ (Hill-type) ===
        % F_i = F_max_i * a^n / (a^n + a50^n)
        a = new_activation;
        if a > 1e-6
            a_n = a^hill_n;
            F_normalized = a_n / (a_n + a50^hill_n);
        else
            F_normalized = 0;
        end

        % -------------------- PATCH B: консистентный масштаб силы MU --------------------
        % ВАЖНО:
        % twitch_amplitude в вашем проекте обычно уже скейлится как "сила MU".
        % Умножение на n_fibers часто даёт двойной масштаб (а после PATCH A может взорвать амплитуду).
        %
        % Было:
        %   F_mu = mu.twitch_amplitude * mu.n_fibers * F_normalized * fatigue_factor;
        % Стало:
        F_mu = mu.twitch_amplitude * F_normalized * fatigue_factor;
        % -------------------- END PATCH B --------------------

        F_total = F_total + F_mu;
    end

    % Также обновляем силу через старую модель twitch_history для совместимости
    % (можно использовать для валидации)
    F_twitch = 0;
    if ~isempty(state.twitch_history)
        max_twitch_duration = 0.3;
        active_twitches = [];

        for k = 1:length(state.twitch_history)
            tw = state.twitch_history(k);
            time_since_start = t - tw.start_time;
            if time_since_start < 0, continue; end

            if time_since_start < max_twitch_duration
                active_twitches(end+1) = k; %#ok<AGROW>
                if time_since_start < tw.rise_time
                    f_tw = tw.amplitude * (1 - exp(-3 * time_since_start / tw.rise_time));
                else
                    f_tw = tw.amplitude * exp(-3 * (time_since_start - tw.rise_time) / tw.fall_time);
                end
                if isnan(f_tw) || isinf(f_tw), f_tw = 0; end
                F_twitch = F_twitch + f_tw;
            end
        end

        if ~isempty(active_twitches)
            state.twitch_history = state.twitch_history(active_twitches);
        else
            state.twitch_history = struct([]);
        end
    end

    % Основная сила — новая модель
    state.force = F_total;

    % Диагностика/валидация
    state.force_twitch_backup = F_twitch;
end


%--------------------------------------------------------------------------
% MODULE: Precompute steady-state force vs. drive curve (LUT)
%
% Purpose:
%   Строит монотонную кривую F_ss(drive) для конкретного пула MU.
%   Контроллер использует обратную кривую drive = F_inv(F_ref) как feedforward.
%
%   Для каждого drive ∈ [0, 1]:
%     1) Рекрутирование: MU с threshold < drive → активны
%     2) Rate coding: fr = fr_min + gain * (drive - threshold), ≤ fr_max
%     3) Стационарная активация: a_ss = sg / (1 - exp(-1/(fr * tau)))
%     4) Hill: F_norm = a^n / (a^n + a50^n)
%     5) Сила MU: F_mu = twitch_amplitude * F_norm
%     6) F_ss = sum(F_mu)
%--------------------------------------------------------------------------
function lut = precompute_force_drive_curve(mu_pool, cfg)
    n_mu = length(mu_pool);
    N_pts = 201;
    drive_vec = linspace(0, 1, N_pts);
    force_vec = zeros(1, N_pts);

    fd_cfg = cfg.motor_units.force_dynamics;
    hill_n = fd_cfg.hill_n;
    a50 = fd_cfg.a50;
    a50_n = a50^hill_n;
    spike_gain_arr = fd_cfg.spike_gain;

    for di = 1:N_pts
        d = drive_vec(di);
        F_total = 0;
        for i = 1:n_mu
            mu = mu_pool(i);
            if d < mu.recruitment_threshold, continue; end

            drive_above = d - mu.recruitment_threshold;
            fr = min(mu.fr_min + mu.fr_gain * drive_above, mu.fr_max);
            fr = max(fr, 1);

            type_idx = mu.type_index;
            if type_idx < 1 || type_idx > 3, type_idx = 1; end
            tau_d = fd_cfg.tau_decay(type_idx);

            if numel(spike_gain_arr) == 1
                sg = spike_gain_arr;
            else
                sg = spike_gain_arr(type_idx);
            end

            % Стационарная активация
            decay_per_isi = exp(-1 / (fr * tau_d));
            a_ss = sg / (1 - decay_per_isi);
            a_ss = min(a_ss, 1.0);

            if a_ss > 1e-6
                a_n = a_ss^hill_n;
                F_norm = a_n / (a_n + a50_n);
            else
                F_norm = 0;
            end

            F_total = F_total + mu.twitch_amplitude * F_norm;
        end
        force_vec(di) = F_total;
    end

    % Гарантируем монотонность
    for di = 2:N_pts
        if force_vec(di) < force_vec(di-1)
            force_vec(di) = force_vec(di-1);
        end
    end

    lut = struct();
    lut.drive = drive_vec;
    lut.force = force_vec;
    lut.F_max_actual = force_vec(end);
end


%--------------------------------------------------------------------------
% MODULE: Basis source generation (precomputed source templates)
%
% Purpose:
%   - Формирует список "базисных" источников (обычно волокна/сегменты),
%     которые потом комбинируются в текущие источники при спайках.
%
% ПАТЧ 3: Добавлены физические параметры волокна для биофизической модели источника
%
% Output:
%   basis_sources : struct array, каждый элемент — источник с геометрией/ориентацией/весом
%--------------------------------------------------------------------------
function basis_sources = generate_basis_sources(mu_pools, geom, cfg)

    basis_sources = [];
    source_id = 1;
    
    % ПАТЧ 3: Получаем биофизические параметры волокон
    if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'use_biophysical_source')
        use_biophys = cfg.fibers.use_biophysical_source;
    else
        use_biophys = false;
    end
    
    if use_biophys
        fiber_cfg = cfg.fibers;
        Cm = fiber_cfg.Cm_F_per_m2;           % Ёмкость мембраны (Ф/м²)
        Vm_peak = fiber_cfg.Vm_peak_mV * 1e-3; % Пиковый Vm (В)
        diam_range_um = fiber_cfg.diam_range_um;  % Диаметры по типам (мкм)
        sigma_i = fiber_cfg.sigma_i;          % Внутриклеточная проводимость
        sigma_e = fiber_cfg.sigma_e;          % Внеклеточная проводимость
    else
        % Значения по умолчанию для обратной совместимости
        Cm = 0.01;
        Vm_peak = 0.1;
        diam_range_um = [30, 50, 70];
        sigma_i = 1.0;
        sigma_e = 0.4;
    end
    
    for m = 1:length(mu_pools)
        mu_pool = mu_pools{m};
        for i = 1:length(mu_pool)
            mu = mu_pool(i);
            
            % Получаем вес волокна для масштабирования (n_fibers / n_representative)
            if isfield(mu, 'fiber_weight')
                fiber_w = mu.fiber_weight;
            else
                fiber_w = 1.0;  % по умолчанию без масштабирования
            end
            
            % ПАТЧ 3: Диаметр волокна зависит от типа MU
            type_idx = mu.type_index;
            if type_idx < 1 || type_idx > 3
                type_idx = 2;  % По умолчанию FR
            end
            fiber_diam_um = diam_range_um(type_idx) * (0.8 + 0.4*rand());  % Вариация ±20%
            fiber_diam_m = fiber_diam_um * 1e-6;
            
            % Радиус волокна
            fiber_radius_m = fiber_diam_m / 2;
            
            % ПАТЧ 3: Вычисляем масштаб источника из биофизики
            % Трансмембранный ток на единицу длины: I_m = pi * d * Cm * dVm/dt
            % При скорости проведения cv: dVm/dt ~ Vm_peak * cv / lambda
            % где lambda ~ w (пространственная ширина AP)
            cv = mu.cv;  % м/с
            
            % Пространственная ширина AP (типично ~2-6 мм)
            ap_dur_s = 3e-3;  % Типичная длительность AP
            lambda_m = max(0.001, 0.5 * cv * ap_dur_s);
            
            % Пиковый трансмембранный ток на единицу длины (А/м)
            % I_m_peak = pi * d * Cm * Vm_peak * cv / lambda
            I_m_peak = pi * fiber_diam_m * Cm * Vm_peak * cv / lambda_m;
            
            % Эквивалентный дипольный момент на единицу длины (А·м/м = А)
            % Для линейного источника в объёмном проводнике
            % p_line = I_m * (sigma_i / (sigma_i + sigma_e)) * lambda / (4*pi)
            % Упрощённо: p_line ~ I_m * effective_length
            sigma_ratio = sigma_i / (sigma_i + sigma_e);
            p_line_Am = I_m_peak * sigma_ratio * lambda_m / (4*pi);
            
            for f = 1:length(mu.fibers)
                fiber = mu.fibers(f);
                for s = 1:length(fiber.segments)
                    z_seg = fiber.segments(s);
                    pos = fiber.position + [0; 0; z_seg];
                    basis_sources(source_id).position = pos;
                    basis_sources(source_id).orientation = fiber.direction;
                    basis_sources(source_id).type = 'dipole';
                    basis_sources(source_id).mu_index = [m, i];
                    basis_sources(source_id).fiber_index = f;
                    basis_sources(source_id).fiber_weight = fiber_w;
                    
                    % ПАТЧ 3: Добавляем биофизические параметры для каждого источника
                    basis_sources(source_id).fiber_diam_m = fiber_diam_m;
                    basis_sources(source_id).p_line_Am = p_line_Am;
                    basis_sources(source_id).cv = cv;
                    basis_sources(source_id).Cm = Cm;
                    basis_sources(source_id).Vm_peak = Vm_peak;
                    
                    source_id = source_id + 1;
                end
            end
        end
    end
end

%--------------------------------------------------------------------------
% MODULE: Source index mapping
%
% Purpose:
%   - Строит отображение: MU -> список индексов basis_sources, которые ему принадлежат.
%   - Нужен, чтобы быстро получить активные источники по списку активных MU.
%--------------------------------------------------------------------------
function source_idx = build_source_index(basis_sources, mu_pools)

    n_muscles = length(mu_pools);
    source_idx = cell(n_muscles, 1);
    
    for m = 1:n_muscles
        n_mus = length(mu_pools{m});
        source_idx{m} = cell(n_mus, 1);
        for mu = 1:n_mus
            n_fibers = length(mu_pools{m}(mu).fibers);
            source_idx{m}{mu} = cell(n_fibers, 1);
            for f = 1:n_fibers, source_idx{m}{mu}{f} = []; end
        end
    end
    
    for s = 1:length(basis_sources)
        source = basis_sources(s);
        m = source.mu_index(1); mu = source.mu_index(2); f = source.fiber_index;
        source_idx{m}{mu}{f}(end+1) = s;
    end
end

%--------------------------------------------------------------------------
% MODULE: Leadfield computation (electrode mapping)
%
% Purpose:
%   - Вычисляет матрицу L, связывающую источники (basis_sources) и потенциалы на электродах:
%       phi_electrodes = L * q_sources
%   - Где q_sources — скаляры/моменты источников в текущий момент.
%
% Output:
%   L : [n_electrodes x n_sources]
%
% Notes:
%   Leadfield — быстрый вариант солвера. FEM обычно точнее, но дороже.
%--------------------------------------------------------------------------
function L = compute_leadfield_matrix(basis_sources, geom, cfg, ea_idx)
% ПАТЧ 7: Улучшенный leadfield с коррекцией границ и анизотропией.
%
% Усовершенствования по сравнению с исходной версией:
%   (A) Корректный учёт анизотропии мышцы через масштабирование координат
%       (Plonsey & Barr, 2007): σ_eq = sqrt(σ_l * σ_t), координаты z
%       масштабируются для приведения к эквивалентной изотропной среде.
%   (B) Коррекция границ слоёв методом коэффициентов отражения
%       (Stegeman et al., 1997): на каждой границе тканей ток частично
%       отражается, что модифицирует потенциал. Доминирующий эффект —
%       граница кожа/воздух (σ_air ≈ 0), увеличивающая потенциал ~×2.
%   (C) Гармоническое среднее σ вдоль луча (сохранено).
%
% При cfg.solver.leadfield_corrections = false используется прежний режим.

    n_sources = length(basis_sources);
    elec_geom = geom.electrode_arrays{ea_idx};
    n_electrodes = elec_geom.n_electrodes;
    L = zeros(n_electrodes, n_sources);

    R_skin   = geom.radii.skin;
    R_fat    = geom.radii.fat;
    R_fascia = geom.radii.fascia;
    R_muscle = geom.radii.muscle;

    % костная зона (в FEM вы тоже так делаете; тут хотя бы согласуем)
    R_bone = max(0.007, min(0.012, 0.6*R_muscle));

    sig_skin = cfg.tissues.skin.sigma;
    sig_fat  = cfg.tissues.fat.sigma;
    sig_fas  = cfg.tissues.fascia.sigma;
    sig_bone = cfg.tissues.bone.sigma;
    sig_m_l  = cfg.tissues.muscle.sigma_long;
    sig_m_t  = cfg.tissues.muscle.sigma_trans;

    % дискретизация луча
    n_path = 9;
    
    % ПАТЧ 7: Флаг коррекции границ (по умолчанию включён)
    use_corrections = true;
    if isfield(cfg, 'solver') && isfield(cfg.solver, 'leadfield_corrections')
        use_corrections = cfg.solver.leadfield_corrections;
    end
    
    % ПАТЧ 7A: Параметры анизотропии мышцы
    % Эквивалентная изотропная проводимость: σ_eq = sqrt(σ_l * σ_t)
    sig_m_eq = sqrt(sig_m_l * sig_m_t);
    % Масштаб z-координаты (вдоль волокна) для анизотропного→изотропного
    % отображения: z' = z * sqrt(σ_t/σ_l)
    z_scale = sqrt(sig_m_t / max(sig_m_l, 1e-9));
    
    % ПАТЧ 7B: Границы слоёв для расчёта коэффициентов отражения
    % (от внутренней к внешней: кость→мышца→фасция→жир→кожа→воздух)
    boundary_radii  = [R_bone,   R_muscle, R_fascia,  R_fat,     R_skin];
    boundary_sig_in = [sig_bone, sig_m_eq, sig_fas,   sig_fat,   sig_skin];
    boundary_sig_out= [sig_m_eq, sig_fas,  sig_fat,   sig_skin,  0       ];
    n_boundaries = length(boundary_radii);

    for s = 1:n_sources
        source = basis_sources(s);
        p0 = source.position(:);
        u_p = source.orientation(:);
        nu = norm(u_p);
        if nu < 1e-12, u_p = [0;0;1]; else, u_p = u_p./nu; end

        % Радиус источника (для определения слоя)
        r_source = hypot(p0(1), p0(2));

        for e = 1:n_electrodes
            pe = elec_geom.positions_3d(:, e);
            r_vec = pe - p0;
            r = norm(r_vec);
            if r < 1e-6, continue; end

            u_r = r_vec / r;

            % ---- (C) sigma_eff как гармоническое среднее вдоль пути ----
            invsig_sum = 0;
            for k = 1:n_path
                tk = (k - 0.5) / n_path;
                q = p0 + tk * r_vec;
                rq = hypot(q(1), q(2));

                if rq <= R_bone
                    Sigma = diag([sig_bone, sig_bone, sig_bone]);
                elseif rq <= R_muscle
                    Sigma = diag([sig_m_t, sig_m_t, sig_m_l]);
                elseif rq <= R_fascia
                    Sigma = diag([sig_fas, sig_fas, sig_fas]);
                elseif rq <= R_fat
                    Sigma = diag([sig_fat, sig_fat, sig_fat]);
                else
                    Sigma = diag([sig_skin, sig_skin, sig_skin]);
                end

                sigma_dir = u_r' * Sigma * u_r;
                sigma_dir = max(sigma_dir, 1e-9);
                invsig_sum = invsig_sum + 1 / sigma_dir;
            end
            sigma_eff = n_path / invsig_sum;

            % ---- Базовый потенциал диполя ----
            if use_corrections && r_source > R_bone && r_source <= R_muscle
                % ПАТЧ 7A: Масштабируем z-координату для учёта анизотропии
                r_vec_sc = r_vec;
                r_vec_sc(3) = r_vec_sc(3) * z_scale;
                r_sc = norm(r_vec_sc);
                if r_sc < 1e-6, r_sc = 1e-6; end

                u_p_sc = u_p;
                u_p_sc(3) = u_p_sc(3) / z_scale;  % обратный масштаб для дипольного момента

                phi = (1 / (4*pi*sigma_eff)) * dot(u_p_sc, r_vec_sc) / (r_sc^3);
            else
                phi = (1 / (4*pi*sigma_eff)) * dot(u_p, r_vec) / (r^3);
            end

            % ---- (B) Коррекция границ методом коэффициентов отражения ----
            if use_corrections
                correction = 1.0;
                r_elec = hypot(pe(1), pe(2));
                r_min_path = min(r_source, r_elec);
                r_max_path = max(r_source, r_elec);

                for b = 1:n_boundaries
                    Rb = boundary_radii(b);
                    % Граница пересекается, если source и electrode по разные стороны
                    if r_min_path < Rb && r_max_path >= Rb
                        s_in  = boundary_sig_in(b);
                        s_out = boundary_sig_out(b);

                        if s_out < 1e-12
                            % Граница с воздухом (Neumann BC): потенциал ×2
                            correction = correction * 2.0;
                        else
                            % Внутренняя граница: трансмиссионный коэффициент
                            % T ≈ 2·σ_in / (σ_in + σ_out) (плоская аппроксимация)
                            correction = correction * (2 * s_in / max(s_in + s_out, 1e-12));
                        end
                    end
                end

                % Электрод на поверхности кожи: Neumann-эффект (если не посчитан выше)
                if r_elec >= R_skin * 0.99 && r_source >= R_skin * 0.99
                    correction = correction * 2.0;
                end

                phi = phi * correction;
            end

            L(e, s) = phi;
        end
    end
end

%--------------------------------------------------------------------------
% MODULE: Farina cylindrical leadfield computation
%
% Purpose:
%   - Вычисляет leadfield матрицу через аналитическую цилиндрическую модель
%   - Более точная физика для цилиндрических конечностей (предплечье, голень)
%   - Учитывает анизотропию мышцы и многослойную структуру
%
% References:
%   [1] Farina D, Merletti R. "A novel approach for precise simulation of
%       the EMG signal detected by surface electrodes." IEEE TBME, 2001.
%   [2] Farina D, et al. "A surface EMG generation model with multilayer
%       cylindrical description." IEEE TBME, 2004.
%
% Inputs:
%   basis_sources : массив структур источников
%   geom          : геометрия (radii, tissues)
%   cfg           : конфигурация
%   ea_idx        : индекс массива электродов
%
% Output:
%   L : leadfield матрица [n_electrodes x n_sources]
%--------------------------------------------------------------------------
function L = compute_leadfield_farina(basis_sources, geom, cfg, ea_idx)
% compute_leadfield_farina - Farina cylindrical leadfield
%
% Delegates to FarinaCylindricalModel class (if available).
% Falls back to built-in implementation otherwise.

    elec_geom = geom.electrode_arrays{ea_idx};
    
    % === Try FarinaCylindricalModel class ===
    use_class = exist('FarinaCylindricalModel', 'class') == 8;
    
    if use_class
        try
            farina = FarinaCylindricalModel(cfg);
            
            % Override with precise geometry from geom
            farina.R_skin   = geom.radii.skin;
            farina.R_fat    = geom.radii.fat;
            farina.R_muscle = geom.radii.muscle;
            farina.R_bone   = max(0.007, min(0.012, 0.6 * geom.radii.muscle));
            
            % Conductivities from cfg
            farina.sigma_bone         = cfg.tissues.bone.sigma;
            farina.sigma_muscle_long  = cfg.tissues.muscle.sigma_long;
            farina.sigma_muscle_trans = cfg.tissues.muscle.sigma_trans;
            farina.sigma_fat          = cfg.tissues.fat.sigma;
            farina.sigma_skin         = cfg.tissues.skin.sigma;
            
            % Solver parameters from cfg.solver.farina
            if isfield(cfg, 'solver') && isfield(cfg.solver, 'farina')
                fc = cfg.solver.farina;
                if isfield(fc, 'n_k_points'),    farina.n_k_points    = fc.n_k_points;    end
                if isfield(fc, 'k_max'),          farina.k_max         = fc.k_max;          end
                if isfield(fc, 'n_bessel_terms'), farina.n_bessel_terms = fc.n_bessel_terms; end
                if isfield(fc, 'use_cache'),      farina.cache_enabled  = fc.use_cache;      end
            end
            
            fprintf('        FarinaCylindricalModel: n_k=%d, k_max=%d, n_bessel=%d\n', ...
                farina.n_k_points, farina.k_max, farina.n_bessel_terms);
            
            % Delegate leadfield computation to class
            L = farina.computeLeadfield(basis_sources, elec_geom.positions_3d, cfg);
            return;
            
        catch e
            warning('EMG:FarinaClass', ...
                'FarinaCylindricalModel failed (%s), falling back to built-in.', e.message);
        end
    end
    
    % === Fallback: built-in implementation ===
    L = compute_leadfield_farina_builtin(basis_sources, geom, cfg, ea_idx);
end

%--------------------------------------------------------------------------
% HELPER: Built-in Farina leadfield (fallback when class unavailable)
%--------------------------------------------------------------------------
function L = compute_leadfield_farina_builtin(basis_sources, geom, cfg, ea_idx)
    n_sources = length(basis_sources);
    elec_geom = geom.electrode_arrays{ea_idx};
    n_electrodes = elec_geom.n_electrodes;
    L = zeros(n_electrodes, n_sources);
    
    R_skin   = geom.radii.skin;
    R_fat    = geom.radii.fat;
    R_muscle = geom.radii.muscle;
    R_bone   = max(0.007, min(0.012, 0.6*R_muscle));
    
    sig_skin = cfg.tissues.skin.sigma;
    sig_fat  = cfg.tissues.fat.sigma;
    sig_bone = cfg.tissues.bone.sigma;
    sig_m_l  = cfg.tissues.muscle.sigma_long;
    sig_m_t  = cfg.tissues.muscle.sigma_trans;
    
    farina_cfg = struct();
    if isfield(cfg, 'solver') && isfield(cfg.solver, 'farina')
        farina_cfg = cfg.solver.farina;
    end
    n_k = getf(farina_cfg, 'n_k_points', 64);
    k_max = getf(farina_cfg, 'k_max', 1500);
    n_bessel = getf(farina_cfg, 'n_bessel_terms', 30);
    
    % ИСПРАВЛЕНО: α = √(σ_long/σ_trans), κ_muscle = k·α (было k/α — ОШИБКА)
    alpha = sqrt(sig_m_l / max(sig_m_t, 1e-10));
    k = linspace(1e-3, k_max, n_k);
    
    fprintf('        Farina built-in (multilayer BVP): n_k=%d, k_max=%d, n_bessel=%d\n', n_k, k_max, n_bessel);
    
    for s = 1:n_sources
        source = basis_sources(s);
        p0 = source.position(:);
        u_p = source.orientation(:);
        nu = norm(u_p);
        if nu < 1e-12, u_p = [0;0;1]; else, u_p = u_p/nu; end
        
        [theta_s, r_s, z_s] = cart2pol(p0(1), p0(2), p0(3));
        
        for e = 1:n_electrodes
            pe = elec_geom.positions_3d(:, e);
            [theta_e, r_e, z_e] = cart2pol(pe(1), pe(2), pe(3));
            
            delta_theta = theta_e - theta_s;
            delta_z = z_e - z_s;
            
            % Монопольный потенциал: φ = ∫ H(k)·cos(k·Δz) dk
            integrand = zeros(1, n_k);
            for ik = 1:n_k
                kk = k(ik);
                km = kk * alpha;   % ИСПРАВЛЕНО: κ_muscle = k·α
                H_k = compute_farina_H_multilayer(kk, km, r_s, r_e, delta_theta, ...
                    R_bone, R_muscle, R_fat, R_skin, ...
                    sig_bone, sig_m_t, sig_fat, sig_skin, n_bessel);
                integrand(ik) = H_k * cos(kk * delta_z);
            end
            phi_monopole = (2 / (2*pi)) * trapz(k, integrand);
            
            % Производная по z (для дипольной компоненты)
            integrand_deriv = zeros(1, n_k);
            for ik = 1:n_k
                kk = k(ik);
                km = kk * alpha;
                H_k = compute_farina_H_multilayer(kk, km, r_s, r_e, delta_theta, ...
                    R_bone, R_muscle, R_fat, R_skin, ...
                    sig_bone, sig_m_t, sig_fat, sig_skin, n_bessel);
                integrand_deriv(ik) = H_k * kk * sin(kk * delta_z);
            end
            dphi_dz = -(2 / (2*pi)) * trapz(k, integrand_deriv);
            
            % Дипольная компонента вдоль z
            phi_dipole = -u_p(3) * dphi_dz;
            
            % Радиальная компонента (численная производная по r)
            u_r = [cos(theta_s); sin(theta_s); 0];
            p_r = dot(u_p, u_r);
            
            dr = 1e-5;
            if abs(p_r) > 1e-6 && r_s + dr <= R_muscle
                H_plus = zeros(1, n_k);
                for ik = 1:n_k
                    kk = k(ik);
                    km = kk * alpha;
                    H_plus(ik) = compute_farina_H_multilayer(kk, km, r_s+dr, r_e, delta_theta, ...
                        R_bone, R_muscle, R_fat, R_skin, ...
                        sig_bone, sig_m_t, sig_fat, sig_skin, n_bessel) * cos(kk * delta_z);
                end
                phi_plus = (2 / (2*pi)) * trapz(k, H_plus);
                dphi_dr = (phi_plus - phi_monopole) / dr;
            else
                dphi_dr = 0;
            end
            
            phi_dipole = phi_dipole - p_r * dphi_dr;
            L(e, s) = phi_dipole;
        end
        
        if mod(s, 50) == 0
            fprintf('        Progress: %d/%d sources\n', s, n_sources);
        end
    end
end

%--------------------------------------------------------------------------
% HELPER: Farina transfer function H(k) — полное решение многослойного BVP
%--------------------------------------------------------------------------
function H = compute_farina_H_multilayer(kk, km, r_s, r_e, delta_theta, ...
    R_bone, R_muscle, R_fat, R_skin, sig_bone, sig_muscle_r, sig_fat, sig_skin, n_bessel)
    % compute_farina_H_multilayer - H(k) для многослойного цилиндра
    %
    % Решает краевую задачу с условиями непрерывности на границах:
    %   кость(0,R1) | мышца(R1,R2) | жир(R2,R3) | кожа(R3,R4)
    %   Нейман: ∂φ/∂r = 0 на R4
    %   Источник: скачок σ_r·∂φ/∂r при r = r_s
    
    if kk < 1e-6, kk = 1e-6; end
    
    R1 = R_bone; R2 = R_muscle; R3 = R_fat; R4 = R_skin;
    
    H = 0;
    for n = 0:n_bessel
        eps_n = 1 + (n > 0);
        
        % --- 1) Upward admittance: центр → r_s ---
        Y_up = sig_bone * kk * farina_dlnI(n, kk * R1);
        Y_up = farina_propagateY(Y_up, sig_muscle_r, km, n, R1, r_s);
        
        % --- 2) Downward admittance: поверхность → r_s ---
        Y_down = 0;  % Нейман на R4
        Y_down = farina_propagateY(Y_down, sig_skin, kk, n, R4, R3);
        Y_down = farina_propagateY(Y_down, sig_fat, kk, n, R3, R2);
        Y_down = farina_propagateY(Y_down, sig_muscle_r, km, n, R2, r_s);
        
        % --- 3) Источник ---
        dY = Y_down - Y_up;
        if abs(dY) < 1e-30, continue; end
        phi_rs = -1 / (2 * pi * r_s * dY);
        
        % --- 4) Propagation r_s → r_e ---
        total_logP = 0;
        total_sign = 1;
        Y_cur = Y_down;
        
        if r_s < R2
            [lp, sp, Y_cur] = farina_logPropagation(Y_cur, sig_muscle_r, km, n, r_s, R2);
            total_logP = total_logP + lp; total_sign = total_sign * sp;
        end
        [lp, sp, Y_cur] = farina_logPropagation(Y_cur, sig_fat, kk, n, R2, R3);
        total_logP = total_logP + lp; total_sign = total_sign * sp;
        if r_e >= R4
            [lp, sp, ~] = farina_logPropagation(Y_cur, sig_skin, kk, n, R3, R4);
        else
            [lp, sp, ~] = farina_logPropagation(Y_cur, sig_skin, kk, n, R3, max(r_e, R3));
        end
        total_logP = total_logP + lp; total_sign = total_sign * sp;
        
        total_logP = max(-500, min(500, total_logP));
        G_n = phi_rs * total_sign * exp(total_logP);
        if ~isfinite(G_n), G_n = 0; end
        
        H = H + eps_n * G_n * cos(n * delta_theta);
    end
end

%--------------------------------------------------------------------------
% HELPER: dlnI = I_n'(x)/I_n(x) через scaled Bessel
%--------------------------------------------------------------------------
function dli = farina_dlnI(n, x)
    x = max(abs(x), 1e-30);
    In_s = besseli(n, x, 1);
    if abs(In_s) < 1e-300, dli = 1; return; end
    if n == 0
        dli = besseli(1, x, 1) / In_s;
    else
        dli = (besseli(n-1, x, 1) + besseli(n+1, x, 1)) / (2 * In_s);
    end
    if ~isfinite(dli), dli = 1; end
end

%--------------------------------------------------------------------------
% HELPER: dlnK = K_n'(x)/K_n(x) через scaled Bessel
%--------------------------------------------------------------------------
function dlk = farina_dlnK(n, x)
    x = max(abs(x), 1e-30);
    Kn_s = besselk(n, x, 1);
    if abs(Kn_s) < 1e-300, dlk = -1; return; end
    if n == 0
        dlk = -besselk(1, x, 1) / Kn_s;
    else
        dlk = -(besselk(n-1, x, 1) + besselk(n+1, x, 1)) / (2 * Kn_s);
    end
    if ~isfinite(dlk), dlk = -1; end
end

%--------------------------------------------------------------------------
% HELPER: Propagation admittance Y через слой (от r_a к r_b)
%--------------------------------------------------------------------------
function Y_b = farina_propagateY(Y_a, sigma_r, kappa, n, r_a, r_b)
    if abs(r_b - r_a) < 1e-12 || kappa < 1e-10
        Y_b = Y_a; return;
    end
    arg_a = kappa * abs(r_a);
    arg_b = kappa * abs(r_b);
    
    alpha_a = Y_a / max(sigma_r * kappa, 1e-30);
    dli_a = farina_dlnI(n, arg_a);
    dlk_a = farina_dlnK(n, arg_a);
    
    denom = dlk_a - alpha_a;
    if abs(denom) < 1e-30
        Y_b = sigma_r * kappa * farina_dlnK(n, arg_b);
        return;
    end
    mu_a = (alpha_a - dli_a) / denom;
    
    In_s_a = besseli(n, arg_a, 1);
    In_s_b = besseli(n, arg_b, 1);
    Kn_s_a = besselk(n, arg_a, 1);
    Kn_s_b = besselk(n, arg_b, 1);
    
    denom_IK = abs(Kn_s_a * In_s_b);
    if denom_IK < 1e-300
        mu_b = 0;
    else
        ratio_s = (Kn_s_b * In_s_a) / (Kn_s_a * In_s_b);
        mu_b = mu_a * ratio_s * exp(-2 * (arg_b - arg_a));
    end
    
    if abs(mu_b) > 1e15
        Y_b = sigma_r * kappa * farina_dlnK(n, arg_b);
        return;
    end
    
    dli_b = farina_dlnI(n, arg_b);
    dlk_b = farina_dlnK(n, arg_b);
    alpha_b = (dli_b + mu_b * dlk_b) / (1 + mu_b);
    Y_b = sigma_r * kappa * alpha_b;
    if ~isfinite(Y_b), Y_b = Y_a; end
end

%--------------------------------------------------------------------------
% HELPER: Propagation потенциала через слой (log-домен)
%--------------------------------------------------------------------------
function [logP, signP, Y_out] = farina_logPropagation(Y_in, sigma_r, kappa, n, r_a, r_b)
    if abs(r_b - r_a) < 1e-12 || kappa < 1e-10
        logP = 0; signP = 1; Y_out = Y_in; return;
    end
    arg_a = kappa * abs(r_a);
    arg_b = kappa * abs(r_b);
    
    alpha_a = Y_in / max(sigma_r * kappa, 1e-30);
    dli_a = farina_dlnI(n, arg_a);
    dlk_a = farina_dlnK(n, arg_a);
    
    denom = dlk_a - alpha_a;
    if abs(denom) < 1e-30
        mu_a = 1e15;
    else
        mu_a = (alpha_a - dli_a) / denom;
    end
    
    In_s_a = besseli(n, arg_a, 1);
    In_s_b = besseli(n, arg_b, 1);
    Kn_s_a = besselk(n, arg_a, 1);
    Kn_s_b = besselk(n, arg_b, 1);
    
    denom_IK = abs(Kn_s_a * In_s_b);
    if denom_IK < 1e-300
        mu_b = 0;
    else
        ratio_s = (Kn_s_b * In_s_a) / (Kn_s_a * In_s_b);
        mu_b = mu_a * ratio_s * exp(-2 * (arg_b - arg_a));
    end
    if abs(mu_b) > 1e15, mu_b = 1e15; end
    
    log_I_ratio = log(max(abs(In_s_b), 1e-300)) - log(max(abs(In_s_a), 1e-300));
    log_mu_ratio = log(max(abs(1 + mu_b), 1e-300)) - log(max(abs(1 + mu_a), 1e-300));
    logP = log_I_ratio + kappa * (r_b - r_a) + log_mu_ratio;
    
    signP = sign((1 + mu_b) / (1 + mu_a));
    if signP == 0, signP = 1; end
    
    dli_b = farina_dlnI(n, arg_b);
    dlk_b = farina_dlnK(n, arg_b);
    if abs(mu_b) > 1e15
        alpha_b = dlk_b;
    else
        alpha_b = (dli_b + mu_b * dlk_b) / (1 + mu_b);
    end
    Y_out = sigma_r * kappa * alpha_b;
    if ~isfinite(Y_out), Y_out = Y_in; end
    if ~isfinite(logP), logP = -500; signP = 1; end
end
%--------------------------------------------------------------------------
% HELPER: Safe getfield with default
%--------------------------------------------------------------------------
function val = getf(s, field, default)
    if isfield(s, field)
        val = s.(field);
    else
        val = default;
    end
end

%--------------------------------------------------------------------------
% HELPER: Ternary string selector (для диагностических сообщений)
%--------------------------------------------------------------------------
function s = ternary_str(cond, s_true, s_false)
    if cond, s = s_true; else, s = s_false; end
end

%--------------------------------------------------------------------------
% MODULE: Active source assembly at time t
%
% Purpose:
%   - По активным MU/событиям в окне MUAP формирует текущий вектор/структуру источников
%     (амплитуды/фазы), который затем подаётся в leadfield или FEM.
%
% Output:
%   sources_current : представление активных источников в момент t
%--------------------------------------------------------------------------
function sources_current = compute_fiber_sources_at_time(active_mu_indices, mu_pool, t, spike_times, muscle_idx, solver_data, cfg)
% Источники задаём как токовый дипольный момент (A*m) вдоль ориентации fiber.direction.
%
% ПАТЧ 4: Интеграция ActionPotentialModel
%   - Поддержка различных моделей IAP: rosenfalck, hh, fhn, gaussian
%   - Кеширование профилей Im для каждого типа волокна
%   - Физически обоснованный мембранный ток вместо упрощённого триполя
%
% ФИЗИОЛОГИЧЕСКИЕ УЛУЧШЕНИЯ:
%   1) Волна MUAP гасится на концах волокна (tendon endings)
%   2) Профиль Im генерируется из биофизической модели IAP
%   3) ПАТЧ 3: Модель экстинкции (Petersen 2019 / Dimitrov-Dimitrova 2006)
%      Вместо косинусного taper — физически обоснованные непропагирующие
%      компоненты на концах волокна: стационарный источник тока,
%      экспоненциально затухающий во времени. Создаёт дополнительные фазы
%      и характерные «хвосты» MUAP. Legacy taper доступен через
%      cfg.sources.muap.use_legacy_taper = true.
%   4) Двунаправленное распространение от NMJ

    persistent iap_cache;  % Кеш профилей Im для разных типов волокон
    
    n_sources = solver_data.n_sources;
    sources_current = zeros(n_sources, 1);

    % ---- ПАРАМЕТРЫ MUAP ----
    muap_cfg = struct();
    if nargin >= 7 && isstruct(cfg) && isfield(cfg, 'sources') && isfield(cfg.sources, 'muap')
        muap_cfg = cfg.sources.muap;
    end

    % ---- ПАРАМЕТРЫ ЭКСТИНКЦИИ (непропагирующие компоненты на концах волокна) ----
    % Petersen (2019) Section 2.2 / Dimitrov-Dimitrova (2006):
    % Когда фронт ПД достигает конца волокна (сухожилия), мембранный ток
    % не исчезает мгновенно, а создаёт стационарный (непропагирующий) источник,
    % экспоненциально затухающий во времени. Этот источник (end-effect / extinction)
    % ответственен за дополнительные фазы и характерные «хвосты» MUAP.
    
    % Постоянная времени экспоненциального затухания экстинкции [с]
    tau_ext = 0.5e-3;   % По умолчанию 0.5 мс (Dimitrov & Dimitrova, 2006)
    if isfield(muap_cfg, 'extinction_tau_s'), tau_ext = muap_cfg.extinction_tau_s; end
    
    % Длительность экстинкции (после 5*tau практически ноль)
    ext_duration = 5 * tau_ext;
    if isfield(muap_cfg, 'extinction_duration_s'), ext_duration = muap_cfg.extinction_duration_s; end
    
    % Пространственная ширина экстинкции (σ Гауссовой огибающей) [м]
    ext_sigma = 0.002;  % 2 мм — характерная ширина зоны конца волокна
    if isfield(muap_cfg, 'extinction_sigma_m'), ext_sigma = muap_cfg.extinction_sigma_m; end
    
    % Амплитудный масштаб экстинкции относительно пика пропагирующего компонента
    ext_amplitude_scale = 0.8;  % 80% от пика — типично для модели Dimitrov
    if isfield(muap_cfg, 'extinction_amplitude'), ext_amplitude_scale = muap_cfg.extinction_amplitude; end
    
    % Обратная совместимость: если задан end_taper_m, переключаемся на legacy taper
    use_legacy_taper = isfield(muap_cfg, 'use_legacy_taper') && muap_cfg.use_legacy_taper;
    taper_m = 0.010;
    if isfield(muap_cfg, 'end_taper_m'), taper_m = muap_cfg.end_taper_m; end
    taper_m = max(0.0, taper_m);

    % Проверяем, используем ли биофизическую модель источника
    use_biophys = isfield(cfg, 'fibers') && isfield(cfg.fibers, 'use_biophysical_source') && ...
                  cfg.fibers.use_biophysical_source;
    
    % Определяем модель IAP
    iap_model_type = 'rosenfalck';  % По умолчанию
    if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'iap_model')
        iap_model_type = cfg.fibers.iap_model;
    end
    
    % Резервный p0 для обратной совместимости (если биофизика отключена)
    p0_fallback = 5e-10;
    if isfield(muap_cfg, 'dipole_moment_Am'), p0_fallback = muap_cfg.dipole_moment_Am; end

    % Инициализация кеша IAP профилей
    if isempty(iap_cache) || ~isfield(iap_cache, 'model_type') || ~strcmp(iap_cache.model_type, iap_model_type)
        iap_cache = initialize_iap_cache(cfg, iap_model_type);
    end

    source_idx = solver_data.source_index{muscle_idx};
    basis_sources = solver_data.basis_sources;

    for idx = 1:length(active_mu_indices)
        mu_idx = active_mu_indices(idx);
        mu = mu_pool(mu_idx);

        dt = t - spike_times(idx);
        if dt < 0, continue; end

        cv = mu.cv; % [m/s]
        type_idx = mu.type_index;  % 1=S, 2=FR, 3=FF
        if type_idx < 1 || type_idx > 3, type_idx = 2; end

        for f_idx = 1:length(mu.fibers)
            fiber = mu.fibers(f_idx);
            
            % Шаг дискретизации
            if isfield(fiber, 'segments') && numel(fiber.segments) >= 2
                dz = mean(diff(fiber.segments));
                if ~isfinite(dz) || dz <= 0, dz = 1e-3; end
            else
                dz = 1e-3;
            end

            % NMJ и концы волокна
            nmj_z = fiber.position(3) + fiber.segments(1) + fiber.length * fiber.nmj_position;
            z0 = fiber.position(3) + fiber.segments(1);
            z1 = fiber.position(3) + fiber.segments(end);
            if z0 > z1, tmp = z0; z0 = z1; z1 = tmp; end

            % Фронты в обе стороны от NMJ
            z_front_p = nmj_z + cv * dt;  % Положительное направление
            z_front_n = nmj_z - cv * dt;  % Отрицательное направление

            % === МОДЕЛЬ ЭКСТИНКЦИИ (Petersen 2019 / Dimitrov-Dimitrova 2006) ===
            % Вместо плавного косинусного затухания (taper), используем физически
            % корректную модель: пропагирующий компонент обрезается на конце волокна,
            % а в точке конца появляется стационарный источник (экстинкция),
            % экспоненциально затухающий во времени.
            
            % Пропагирующие компоненты: активны пока фронт внутри волокна
            front_p_active = (z_front_p >= z0) && (z_front_p <= z1);
            front_n_active = (z_front_n >= z0) && (z_front_n <= z1);
            
            % Время прибытия фронтов на концы волокна
            t_arrive_p_at_z1 = (z1 - nmj_z) / cv;  % + фронт → z1
            t_arrive_n_at_z0 = (nmj_z - z0) / cv;   % - фронт → z0
            
            % Время, прошедшее с момента экстинкции
            t_ext_p = dt - t_arrive_p_at_z1;  % Экстинкция + фронта на z1
            t_ext_n = dt - t_arrive_n_at_z0;  % Экстинкция - фронта на z0
            
            if ~use_legacy_taper
                % === ФИЗИЧЕСКАЯ МОДЕЛЬ ЭКСТИНКЦИИ ===
                ext_p_active = (t_ext_p >= 0) && (t_ext_p < ext_duration);
                ext_n_active = (t_ext_n >= 0) && (t_ext_n < ext_duration);
                
                % Вычисляем множитель экспоненциального затухания
                if ext_p_active
                    ext_p_decay = exp(-t_ext_p / tau_ext);
                else
                    ext_p_decay = 0;
                end
                if ext_n_active
                    ext_n_decay = exp(-t_ext_n / tau_ext);
                else
                    ext_n_decay = 0;
                end
            else
                ext_p_active = false;
                ext_n_active = false;
                ext_p_decay = 0;
                ext_n_decay = 0;
            end
            
            % Проверка: есть ли хоть один активный компонент?
            if ~front_p_active && ~front_n_active && ~ext_p_active && ~ext_n_active
                continue;
            end

            if isempty(source_idx{mu_idx}{f_idx}), continue; end
            s_indices = source_idx{mu_idx}{f_idx};

            % Получаем профиль Im из кеша
            if use_biophys && ~isempty(iap_cache) && isfield(iap_cache, 'Im')
                Im_profile = iap_cache.Im{type_idx};
                z_profile = iap_cache.z{type_idx};
                ap_length = iap_cache.ap_length(type_idx);
            else
                Im_profile = [];
                z_profile = [];
                ap_length = cv * 3e-3;  % ~3 мс * cv
            end
            
            % Пиковая амплитуда Im для масштабирования экстинкции
            if ~isempty(Im_profile)
                Im_peak = max(abs(Im_profile));
            else
                Im_peak = 1.0;  % нормализовано для legacy режима
            end

            % Вклад каждого базисного источника
            for s_idx = s_indices
                z = basis_sources(s_idx).position(3);

                % Определяем длительность AP (нужно для обоих режимов)
                ap_dur_s = 3e-3;
                if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'AP_duration_ms')
                    ap_dur_s = cfg.fibers.AP_duration_ms * 1e-3;
                end
                
                % === ВЫЧИСЛЕНИЕ ВКЛАДА ИСТОЧНИКА ===
                
                if use_legacy_taper
                    % --- LEGACY РЕЖИМ С TAPER (обратная совместимость) ---
                    taper_w = 1.0;
                    if taper_m > 0
                        if front_p_active
                            dist_to_end_p = min(abs(z_front_p - z0), abs(z1 - z_front_p));
                            taper_w_p = end_taper_window(dist_to_end_p, taper_m);
                        else
                            taper_w_p = 0.0;
                        end
                        if front_n_active
                            dist_to_end_n = min(abs(z_front_n - z0), abs(z1 - z_front_n));
                            taper_w_n = end_taper_window(dist_to_end_n, taper_m);
                        else
                            taper_w_n = 0.0;
                        end
                        taper_w = max(taper_w_p, taper_w_n);
                    end
                end

                Im_total = 0;
                
                if use_biophys && ~isempty(Im_profile)
                    % ============================================
                    % БИОФИЗИЧЕСКАЯ МОДЕЛЬ с экстинкцией
                    % ============================================
                    
                    % (A) Пропагирующий компонент — жёсткая обрезка на концах
                    if front_p_active
                        z_rel_p = z - z_front_p;
                        if z_rel_p >= -ap_length && z_rel_p <= ap_length
                            Im_p = interp1(z_profile - z_profile(end)/2, Im_profile, z_rel_p, 'pchip', 0);
                            if use_legacy_taper
                                Im_total = Im_total + Im_p * taper_w_p;
                            else
                                Im_total = Im_total + Im_p;  % Жёсткая обрезка, без taper
                            end
                        end
                    end
                    
                    if front_n_active
                        z_rel_n = z - z_front_n;
                        if z_rel_n >= -ap_length && z_rel_n <= ap_length
                            Im_n = interp1(z_profile - z_profile(end)/2, Im_profile, -z_rel_n, 'pchip', 0);
                            if use_legacy_taper
                                Im_total = Im_total + Im_n * taper_w_n;
                            else
                                Im_total = Im_total + Im_n;  % Жёсткая обрезка, без taper
                            end
                        end
                    end
                    
                    % (B) Непропагирующие компоненты (экстинкция) на концах
                    if ~use_legacy_taper
                        % Экстинкция + фронта на конце z1
                        if ext_p_active
                            z_rel_ext = z - z1;
                            % Пространственная Гауссова огибающая, центрированная на конце
                            spatial_w = exp(-0.5 * (z_rel_ext / ext_sigma)^2);
                            % Знак: экстинкция создаёт ток того же знака, что пик
                            % прибывающей волны (ток «утекает» через мембрану на конце)
                            Im_ext_p = ext_amplitude_scale * Im_peak * spatial_w * ext_p_decay;
                            Im_total = Im_total + Im_ext_p;
                        end
                        
                        % Экстинкция - фронта на конце z0
                        if ext_n_active
                            z_rel_ext = z - z0;
                            spatial_w = exp(-0.5 * (z_rel_ext / ext_sigma)^2);
                            Im_ext_n = ext_amplitude_scale * Im_peak * spatial_w * ext_n_decay;
                            Im_total = Im_total + Im_ext_n;
                        end
                    end
                    
                    % Масштабируем по весу волокна
                    if isfield(basis_sources(s_idx), 'fiber_weight')
                        fiber_w = basis_sources(s_idx).fiber_weight;
                    else
                        fiber_w = 1.0;
                    end
                    
                    % Итоговый дипольный момент [А·м]
                    d_dipole = 0.5 * cv * ap_dur_s;
                    d_dipole = max(0.001, min(0.010, d_dipole));
                    
                    sources_current(s_idx) = sources_current(s_idx) + Im_total * dz * d_dipole * fiber_w;
                    
                else
                    % ============================================
                    % LEGACY РЕЖИМ: Гауссов триполь с экстинкцией
                    % ============================================
                    w_loc = max(0.001, 0.5 * cv * ap_dur_s);
                    d_trip_loc = max(0.001, 1.3 * w_loc);
                    
                    % (A) Пропагирующий триполь — жёсткая обрезка на концах
                    if front_p_active
                        dp = exp(-0.5 * ((z - (z_front_p - d_trip_loc))/w_loc)^2) ...
                           - 2*exp(-0.5 * ((z - z_front_p)/w_loc)^2) ...
                           + exp(-0.5 * ((z - (z_front_p + d_trip_loc))/w_loc)^2);
                    else
                        dp = 0;
                    end

                    if front_n_active
                        dn = exp(-0.5 * ((z - (z_front_n - d_trip_loc))/w_loc)^2) ...
                           - 2*exp(-0.5 * ((z - z_front_n)/w_loc)^2) ...
                           + exp(-0.5 * ((z - (z_front_n + d_trip_loc))/w_loc)^2);
                    else
                        dn = 0;
                    end

                    % Вес волокна для масштабирования
                    if isfield(basis_sources(s_idx), 'fiber_weight')
                        fiber_w = basis_sources(s_idx).fiber_weight;
                    else
                        fiber_w = 1.0;
                    end
                    
                    % Используем биофизический масштаб если доступен
                    if isfield(basis_sources(s_idx), 'p_line_Am')
                        p_source = basis_sources(s_idx).p_line_Am;
                    else
                        p_source = p0_fallback;
                    end
                    
                    % (B) Непропагирующие компоненты (экстинкция) для legacy режима
                    d_ext = 0;
                    if ~use_legacy_taper
                        % Экстинкция + фронта на конце z1
                        if ext_p_active
                            spatial_w = exp(-0.5 * ((z - z1) / ext_sigma)^2);
                            d_ext = d_ext + ext_amplitude_scale * spatial_w * ext_p_decay;
                        end
                        % Экстинкция - фронта на конце z0
                        if ext_n_active
                            spatial_w = exp(-0.5 * ((z - z0) / ext_sigma)^2);
                            d_ext = d_ext + ext_amplitude_scale * spatial_w * ext_n_decay;
                        end
                    end
                    
                    if use_legacy_taper
                        sources_current(s_idx) = sources_current(s_idx) + (p_source * dz * taper_w * fiber_w) * (dp + dn);
                    else
                        sources_current(s_idx) = sources_current(s_idx) + (p_source * dz * fiber_w) * (dp + dn + d_ext);
                    end
                end
            end
        end
    end
end

%--------------------------------------------------------------------------
% HELPER: Initialize IAP profile cache
%--------------------------------------------------------------------------
function cache = initialize_iap_cache(cfg, model_type)
% Инициализирует кеш профилей Im для типов волокон S, FR, FF
%
% Это позволяет не пересчитывать модель IAP на каждом временном шаге

    cache = struct();
    cache.model_type = model_type;
    cache.Im = cell(3, 1);
    cache.z = cell(3, 1);
    cache.Vm = cell(3, 1);
    cache.ap_length = zeros(3, 1);
    
    % Параметры по типам волокон
    if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'diam_range_um')
        diams = cfg.fibers.diam_range_um;
    else
        diams = [35, 50, 65];  % S, FR, FF
    end
    
    if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'cv_range')
        cvs = cfg.fibers.cv_range;
    else
        cvs = [3.0, 4.0, 5.0];  % S, FR, FF
    end
    
    % Общие параметры
    ap_dur_ms = 3.0;
    if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'AP_duration_ms')
        ap_dur_ms = cfg.fibers.AP_duration_ms;
    end
    
    Vm_rest = -85e-3;
    Vm_peak = 30e-3;
    if isfield(cfg, 'fibers')
        if isfield(cfg.fibers, 'Vm_rest_mV')
            Vm_rest = cfg.fibers.Vm_rest_mV * 1e-3;
        end
        if isfield(cfg.fibers, 'Vm_peak_mV')
            Vm_peak = cfg.fibers.Vm_peak_mV * 1e-3;
        end
    end
    
    Cm = 1.0;
    if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'Cm_uF_per_cm2')
        Cm = cfg.fibers.Cm_uF_per_cm2;
    end
    
    % Попытка использовать ActionPotentialModel (если доступен)
    use_apm = exist('ActionPotentialModel', 'class') == 8;
    
    for type_idx = 1:3
        if use_apm
            try
                % Используем ActionPotentialModel
                model = ActionPotentialModel(model_type);
                model.fiber_diameter_um = diams(type_idx);
                model.cv = cvs(type_idx);
                model.AP_duration_ms = ap_dur_ms;
                model.V_rest = Vm_rest;
                model.V_peak = Vm_peak;
                model.Cm = Cm;
                
                [Vm, Im, z] = model.generate();
                
                cache.Vm{type_idx} = Vm;
                cache.Im{type_idx} = Im;
                cache.z{type_idx} = z;
                cache.ap_length(type_idx) = z(end);
                
            catch
                % Fallback на встроенную модель
                [Vm, Im, z] = builtin_rosenfalck_model(diams(type_idx), cvs(type_idx), ap_dur_ms, Vm_rest, Vm_peak, Cm);
                cache.Vm{type_idx} = Vm;
                cache.Im{type_idx} = Im;
                cache.z{type_idx} = z;
                cache.ap_length(type_idx) = z(end);
            end
        else
            % Встроенная реализация модели Rosenfalck
            [Vm, Im, z] = builtin_rosenfalck_model(diams(type_idx), cvs(type_idx), ap_dur_ms, Vm_rest, Vm_peak, Cm);
            cache.Vm{type_idx} = Vm;
            cache.Im{type_idx} = Im;
            cache.z{type_idx} = z;
            cache.ap_length(type_idx) = z(end);
        end
    end
end

%--------------------------------------------------------------------------
% HELPER: Built-in Rosenfalck model (fallback when ActionPotentialModel not available)
%--------------------------------------------------------------------------
function [Vm, Im, z] = builtin_rosenfalck_model(diam_um, cv, ap_dur_ms, V_rest, V_peak, Cm)
% Встроенная реализация модели Rosenfalck для случая, когда ActionPotentialModel недоступен
%
% Формула Rosenfalck: Vm(z) = A * z^3 * exp(-z/lambda)

    % Пространственная сетка
    window_mm = 15;  % мм
    n_points = 150;
    z = linspace(0, window_mm * 1e-3, n_points);
    z_mm = z * 1000;
    
    % Параметры Rosenfalck
    A = 96;  % мВ/мм³
    lambda = 1.0;  % мм
    
    % Трансмембранный потенциал
    Vm_mV = A * (z_mm.^3) .* exp(-z_mm / lambda);
    
    % Нормализация к реальной амплитуде AP
    AP_amplitude = V_peak - V_rest;
    Vm_max = max(Vm_mV);
    if Vm_max > 0
        Vm_mV = Vm_mV * (AP_amplitude * 1000) / Vm_max;
    end
    Vm = V_rest + Vm_mV * 1e-3;
    
    % Вторая производная для Im
    % d²/dz²[A·z³·exp(-z/λ)] = A·exp(-z/λ)·(6z − 6z²/λ + z³/λ²)
    % ИСПРАВЛЕНО: убран лишний /λ²
    d2Vm_dz2_mV_mm2 = A * exp(-z_mm/lambda) .* ...
        (6*z_mm - 6*z_mm.^2/lambda + z_mm.^3/lambda^2);
    
    if Vm_max > 0
        d2Vm_dz2_mV_mm2 = d2Vm_dz2_mV_mm2 * (AP_amplitude * 1000) / Vm_max;
    end
    
    % Конвертируем: мВ/мм² -> В/м²
    d2Vm_dz2 = d2Vm_dz2_mV_mm2 * 1e-3 * 1e6;
    
    % Мембранный ток на единицу длины [А/м]
    % Im = (π·a²·σi) · ∂²Vm/∂z²
    a = diam_um * 1e-6 / 2;  % Радиус в метрах
    Ri = 125;  % Ом·см
    sigma_i = 1 / (Ri * 1e-2);  % См/м
    
    Im = pi * a^2 * sigma_i * d2Vm_dz2;
end

function w = end_taper_window(dist_to_end, taper_m)
% end_taper_window (LEGACY — используется только при use_legacy_taper = true)
% Мягкое затухание фронта MUAP вблизи концов волокна.
% ВНИМАНИЕ: Физически некорректно — заменено моделью экстинкции (ПАТЧ 3).
% Оставлено для обратной совместимости.
% dist_to_end: расстояние фронта до ближайшего конца [m]
% taper_m: длина зоны затухания [m]
% Выход: коэффициент 0..1
    if taper_m <= 0
        w = 1.0;
        return;
    end
    x = max(0.0, min(1.0, dist_to_end / taper_m));
    w = 0.5 - 0.5*cos(pi*x);
end


%% FEM ФУНКЦИИ

%--------------------------------------------------------------------------
% MODULE: FEM mesh generation
%
% Purpose:
%   - Строит объёмную сетку (узлы/элементы) проводника для FEM.
%
% Output:
%   mesh.nodes    : [N x 3]
%   mesh.elements : [M x k] (k зависит от типа элементов)
%--------------------------------------------------------------------------
function mesh = build_volume_mesh(geom, cfg)
% ПАТЧ FEM: Полностью переработанная генерация сетки.
%
% Ключевые улучшения:
%   (1) Адаптивное разрешение: мелкая сетка (~2мм) вблизи электродов и мышц,
%       грубая (~6мм) в глубине для экономии памяти.
%   (2) Гарантированные узлы на поверхности кожи (для электродов).
%   (3) Гарантированные узлы на границах тканей (для корректного Sigma).
%   (4) Корректное назначение тканей по узлам, а не только центроидам.

    L = geom.length; R_skin = geom.radii.skin;
    R_fat = geom.radii.fat; R_fascia = geom.radii.fascia; R_muscle = geom.radii.muscle;
    R_bone = max(0.007, min(0.012, 0.6*R_muscle));
    
    if ~isfield(cfg, 'fem'), cfg.fem = struct(); end
    if ~isfield(cfg.fem, 'h_fine'),  cfg.fem.h_fine = 0.003;  end  % 3мм у поверхности
    if ~isfield(cfg.fem, 'h_coarse'), cfg.fem.h_coarse = 0.006; end  % 6мм в глубине
    if ~isfield(cfg.fem, 'h_z'),     cfg.fem.h_z = 0.005;     end  % 5мм вдоль z
    
    h_fine = cfg.fem.h_fine;
    h_coarse = cfg.fem.h_coarse;
    hz = cfg.fem.h_z;
    
    % --- Z-координаты ---
    z_vec = 0:hz:L;
    if abs(z_vec(end) - L) > 1e-6, z_vec(end+1) = L; end
    
    % --- Радиальные кольца на границах тканей ---
    % Гарантируем узлы точно на границах для корректного назначения проводимости
    boundary_radii = unique([R_bone, R_muscle, R_fascia, R_fat, R_skin]);
    boundary_radii = boundary_radii(boundary_radii > 0);
    
    pts_all = [];
    
    % (1) Кольца на каждой границе ткани
    for bi = 1:length(boundary_radii)
        Rb = boundary_radii(bi);
        % Число точек по окружности: пропорционально периметру / h
        if Rb >= R_fat
            n_th = max(24, round(2*pi*Rb / h_fine));
        else
            n_th = max(16, round(2*pi*Rb / h_coarse));
        end
        th = linspace(0, 2*pi, n_th+1); th(end) = [];
        [TH, ZZ] = meshgrid(th, z_vec);
        ring = [Rb*cos(TH(:)), Rb*sin(TH(:)), ZZ(:)];
        pts_all = [pts_all; ring];
    end
    
    % (2) Заполнение объёма: адаптивный шаг
    % Внешние слои (жир+кожа): мелкий шаг
    for r_val = (R_fat + h_fine) : h_fine : (R_skin - h_fine/2)
        n_th = max(12, round(2*pi*r_val / h_fine));
        th = linspace(0, 2*pi, n_th+1); th(end) = [];
        [TH, ZZ] = meshgrid(th, z_vec);
        ring = [r_val*cos(TH(:)), r_val*sin(TH(:)), ZZ(:)];
        pts_all = [pts_all; ring];
    end
    
    % Мышечная область: средний шаг
    h_muscle = (h_fine + h_coarse) / 2;
    for r_val = (R_bone + h_muscle) : h_muscle : (R_muscle - h_muscle/2)
        n_th = max(12, round(2*pi*r_val / h_muscle));
        th = linspace(0, 2*pi, n_th+1); th(end) = [];
        [TH, ZZ] = meshgrid(th, z_vec);
        ring = [r_val*cos(TH(:)), r_val*sin(TH(:)), ZZ(:)];
        pts_all = [pts_all; ring];
    end
    
    % Фасция: мелкий шаг (тонкий слой — нужно хотя бы 1 ряд)
    r_fasc_mid = (R_muscle + R_fascia) / 2;
    if abs(R_fascia - R_muscle) > h_fine
        n_th = max(16, round(2*pi*r_fasc_mid / h_fine));
        th = linspace(0, 2*pi, n_th+1); th(end) = [];
        [TH, ZZ] = meshgrid(th, z_vec);
        ring = [r_fasc_mid*cos(TH(:)), r_fasc_mid*sin(TH(:)), ZZ(:)];
        pts_all = [pts_all; ring];
    end
    
    % Костная область: грубый шаг
    if R_bone > h_coarse
        for r_val = h_coarse : h_coarse : (R_bone - h_coarse/2)
            n_th = max(8, round(2*pi*r_val / h_coarse));
            th = linspace(0, 2*pi, n_th+1); th(end) = [];
            [TH, ZZ] = meshgrid(th, z_vec);
            ring = [r_val*cos(TH(:)), r_val*sin(TH(:)), ZZ(:)];
            pts_all = [pts_all; ring];
        end
    end
    
    % Центральная ось (r=0)
    center_pts = [zeros(length(z_vec), 2), z_vec(:)];
    pts_all = [pts_all; center_pts];
    
    % Убираем дубликаты
    pts_all = unique(round(pts_all, 5), 'rows');
    
    % --- Тесселяция Делоне ---
    dt = delaunayTriangulation(pts_all);
    elems = dt.ConnectivityList;
    nodes = dt.Points;
    
    % Фильтрация элементов вне цилиндра
    C = (nodes(elems(:,1),:) + nodes(elems(:,2),:) + nodes(elems(:,3),:) + nodes(elems(:,4),:)) / 4;
    rc = hypot(C(:,1), C(:,2));
    keep = rc <= (R_skin + h_fine * 0.5);
    elems = elems(keep, :);
    C = C(keep, :);
    
    % --- Назначение тканей ---
    rc = hypot(C(:,1), C(:,2));
    tissue = ones(size(rc));  % default: skin
    tissue(rc <= R_fat)    = 2;  % fat
    tissue(rc <= R_fascia) = 3;  % fascia
    tissue(rc <= R_muscle) = 4;  % muscle
    tissue(rc <= R_bone)   = 5;  % bone
    
    % Фильтрация вырожденных элементов
    vols = zeros(size(elems,1), 1);
    for e = 1:size(elems,1)
        p1 = nodes(elems(e,1),:); p2 = nodes(elems(e,2),:);
        p3 = nodes(elems(e,3),:); p4 = nodes(elems(e,4),:);
        vols(e) = abs(det([p2-p1; p3-p1; p4-p1])) / 6;
    end
    good = vols > 1e-15;
    elems = elems(good,:);
    tissue = tissue(good);
    
    mesh = struct('nodes', nodes, 'elements', elems, 'tissue_labels', tissue);
    
    fprintf('        FEM mesh: %d nodes, %d elements (h_fine=%.1fmm, h_coarse=%.1fmm)\n', ...
        size(nodes,1), size(elems,1), h_fine*1000, h_coarse*1000);
end

%--------------------------------------------------------------------------
% MODULE: FEM stiffness matrix assembly (ПАТЧ FEM)
%
% Ключевые улучшения:
%   (1) Корректная формула элементной матрицы жёсткости для линейного тетраэдра
%   (2) Учёт анизотропии мышцы
%   (3) Робастное вычисление (skip вырожденных элементов)
%--------------------------------------------------------------------------
function K = assemble_stiffness_matrix(mesh, ~, cfg)
    nodes = mesh.nodes; elems = mesh.elements; labels = mesh.tissue_labels;
    n_nodes = size(nodes, 1); n_elems = size(elems, 1);
    
    % Preallocate COO triplets
    I = zeros(n_elems*16, 1); J = zeros(n_elems*16, 1); V = zeros(n_elems*16, 1);
    ptr = 1;
    
    sig_skin = cfg.tissues.skin.sigma;
    sig_fat  = cfg.tissues.fat.sigma;
    sig_fas  = cfg.tissues.fascia.sigma;
    sig_bone = cfg.tissues.bone.sigma;
    sig_m_l  = cfg.tissues.muscle.sigma_long;
    sig_m_t  = cfg.tissues.muscle.sigma_trans;
    
    for e = 1:n_elems
        idx = elems(e, :);
        p1 = nodes(idx(1), :); p2 = nodes(idx(2), :);
        p3 = nodes(idx(3), :); p4 = nodes(idx(4), :);
        
        % Матрица формы [1 x y z] для линейного тетраэдра
        A_mat = [1 p1; 1 p2; 1 p3; 1 p4];
        d_A = det(A_mat);
        if abs(d_A) < 1e-25, continue; end  % вырожденный элемент
        
        invA = A_mat \ eye(4);
        G = invA(2:4, :);  % 3×4: градиенты функций формы
        
        vol = abs(d_A) / 6;
        
        % Тензор проводимости
        switch labels(e)
            case 1, Sigma = diag([sig_skin, sig_skin, sig_skin]);
            case 2, Sigma = diag([sig_fat, sig_fat, sig_fat]);
            case 3, Sigma = diag([sig_fas, sig_fas, sig_fas]);
            case 4, Sigma = diag([sig_m_t, sig_m_t, sig_m_l]);
            case 5, Sigma = diag([sig_bone, sig_bone, sig_bone]);
            otherwise, Sigma = diag([sig_skin, sig_skin, sig_skin]);
        end
        
        % Ke = vol * G' * Sigma * G (стандартная формула для линейного тетраэдра)
        SG = Sigma * G;  % 3×4
        Ke = vol * (G' * SG);  % 4×4
        
        for a = 1:4
            for b = 1:4
                I(ptr) = idx(a); J(ptr) = idx(b); V(ptr) = Ke(a,b); ptr = ptr + 1;
            end
        end
    end
    
    I = I(1:ptr-1); J = J(1:ptr-1); V = V(1:ptr-1);
    K = sparse(I, J, V, n_nodes, n_nodes);
    % Симметризация и регуляризация
    K = 0.5 * (K + K');
end

%--------------------------------------------------------------------------
% MODULE: FEM mappings (ПАТЧ FEM v3.2 — аналитический диполь + face-neighbor smoothing)
%
% Метод инъекции: subtraction approach (Yan 1991, Wolters 2007)
%   b_i = Σ (p⃗ · ∇N_i)
%
% Сглаживание (v3.2):
%   Для линейных тетраэдров gradN = const → позиция внутри элемента
%   не влияет → скачки при переходе между элементами.
%
%   Решение: находим содержащий элемент E0 и его соседей по граням.
%   Для E0 вес = максимальная барицентрическая координата (λ_max),
%   для соседа через грань напротив узла j: вес = λ_j.
%   Λ_j показывает, насколько точка близка к грани,
%   и когда точка переходит в соседний элемент, веса плавно переключаются.
%   
%   Нормализуем: w_total = Σ w_i, каждый вес /= w_total.
%   Это обеспечивает C0-непрерывность потенциала при движении источника.
%--------------------------------------------------------------------------
function fem = prepare_fem_mappings(mesh, geom, cfg, basis_sources, ea_idx)
    fem = struct();
    nodes = mesh.nodes; R_skin = geom.radii.skin;
    elems = mesh.elements;
    n_nodes = size(nodes, 1);
    n_elems = size(elems, 1);
    
    % Оценка характерного шага сетки
    h_mesh = fem_estimate_h(nodes);
    fem.h_mesh = h_mesh;
    
    surface_tol = max(1e-3, 2.0 * h_mesh);
    r = hypot(nodes(:,1), nodes(:,2));
    fem.surface_nodes = find(abs(r - R_skin) <= surface_tol);
    
    elec_geom = geom.electrode_arrays{ea_idx};
    ea_cfg = cfg.electrode_arrays{ea_idx};
    
    A = max(ea_cfg.size(1), eps) * max(ea_cfg.size(2), eps);
    fem.electrode_radius = sqrt(A/pi);
    
    fem.electrode_nodes = cell(elec_geom.n_electrodes, 1);
    for e = 1:elec_geom.n_electrodes
        c = elec_geom.positions_3d(:, e)';
        fem.electrode_nodes{e} = fem_nodes_near_point_on_surface(nodes, fem.surface_nodes, c, fem.electrode_radius);
    end
    
    % === Ground node для Dirichlet BC ===
    % ПАТЧ FEM v3.2: Ground НЕ на электроде!
    %
    % Проблема старого подхода:
    %   Ground на reference_electrode → phi(ref) = 0 принудительно →
    %   искусственный токовый сток на поверхности кожи → искажение
    %   потенциалов на ВСЕХ электродах, особенно соседних.
    %
    % Правильный подход:
    %   Dirichlet BC на удалённом узле (торец цилиндра, z=0 или z=L),
    %   далеко от электродов и источников. Там потенциал естественно ≈ 0.
    %   Это не вносит искусственных токов в зону интереса.
    %
    % После решения: потенциалы на электродах — абсолютные,
    %   дифференциальное вычитание в усилителе (или spatial filter)
    %   делается корректно в frontend.
    
    % Выбираем ground далеко от электродов: на торце z=0 (или z=L),
    % на поверхности цилиндра (r ≈ R_skin)
    r_nodes = hypot(nodes(:,1), nodes(:,2));
    surface_mask = abs(r_nodes - R_skin) < surface_tol;
    
    % Центр z электродного массива
    z_elec_center = mean(elec_geom.positions_3d(3, :));
    
    % Кандидаты: поверхностные узлы на торцах
    z_all = nodes(:, 3);
    z_min = min(z_all); z_max = max(z_all);
    
    % Выбираем торец, наиболее удалённый от центра электродов
    if abs(z_elec_center - z_min) > abs(z_elec_center - z_max)
        % z=0 дальше
        torec_mask = surface_mask & (z_all < z_min + 2*h_mesh);
    else
        % z=L дальше
        torec_mask = surface_mask & (z_all > z_max - 2*h_mesh);
    end
    
    if any(torec_mask)
        torec_idx = find(torec_mask);
        % Из торцевых узлов — самый далёкий от центра электродов
        d2_from_elec = sum((nodes(torec_idx,:) - [0, 0, z_elec_center]).^2, 2);
        [~, best] = max(d2_from_elec);
        fem.ground_node = torec_idx(best);
    else
        % Fallback: самый далёкий поверхностный узел от центра электродов
        if any(surface_mask)
            surf_idx = find(surface_mask);
            d2 = sum((nodes(surf_idx,:) - [0, 0, z_elec_center]).^2, 2);
            [~, best] = max(d2);
            fem.ground_node = surf_idx(best);
        else
            % Последний fallback: самый далёкий узел вообще
            d2 = sum((nodes - [0, 0, z_elec_center]).^2, 2);
            [~, fem.ground_node] = max(d2);
        end
    end
    
    fprintf('        FEM ground node: #%d at [%.1f, %.1f, %.1f] mm (distant from electrodes)\n', ...
        fem.ground_node, nodes(fem.ground_node,:)*1000);
    
    % === Предрасчёт gradN для всех элементов ===
    elem_gradN = zeros(3, 4, n_elems);
    elem_invA = zeros(4, 4, n_elems);  % для быстрых бариц. координат
    elem_ok = false(n_elems, 1);
    for e = 1:n_elems
        idx = elems(e, :);
        A_mat = [1 nodes(idx(1),:); 1 nodes(idx(2),:); ...
                 1 nodes(idx(3),:); 1 nodes(idx(4),:)];
        d_A = det(A_mat);
        if abs(d_A) < 1e-30, continue; end
        invA = A_mat \ eye(4);
        elem_gradN(:,:,e) = invA(2:4,:);
        elem_invA(:,:,e) = invA;
        elem_ok(e) = true;
    end
    fem.elem_gradN = elem_gradN;
    fem.elem_invA = elem_invA;
    fem.elem_ok = elem_ok;
    
    % === Построить face-neighbor map ===
    % Для каждого элемента: 4 соседа (через 4 грани).
    % Грань напротив узла j состоит из остальных 3 узлов.
    % Сосед — элемент, который содержит те же 3 узла.
    face_neighbor = zeros(n_elems, 4);  % face_neighbor(e,j) = сосед напротив узла j
    
    % Строим hash: для каждой грани (3 узла, отсортированных) → список элементов
    face_map = containers.Map('KeyType', 'char', 'ValueType', 'any');
    face_local = [2 3 4; 1 3 4; 1 2 4; 1 2 3];  % грань напротив узла j
    
    for e = 1:n_elems
        if ~elem_ok(e), continue; end
        idx = elems(e, :);
        for j = 1:4
            face_nodes = sort(idx(face_local(j,:)));
            key = sprintf('%d_%d_%d', face_nodes(1), face_nodes(2), face_nodes(3));
            if face_map.isKey(key)
                other = face_map(key);
                face_neighbor(e, j) = other(1);  % первый найденный сосед
                % Обратная ссылка: найти какой j у соседа
                idx_other = elems(other(1), :);
                for jj = 1:4
                    fn_other = sort(idx_other(face_local(jj,:)));
                    if isequal(fn_other, face_nodes)
                        face_neighbor(other(1), jj) = e;
                        break;
                    end
                end
            else
                face_map(key) = e;
            end
        end
    end
    fem.face_neighbor = face_neighbor;
    
    % === Предрасчёт инъекции для каждого источника ===
    n_sources = length(basis_sources);
    centroids = (nodes(elems(:,1),:) + nodes(elems(:,2),:) + ...
                 nodes(elems(:,3),:) + nodes(elems(:,4),:)) / 4;
    
    fem.source_inject = cell(n_sources, 1);
    n_missed = 0;
    
    for s = 1:n_sources
        p = basis_sources(s).position(:)';
        
        % Найти содержащий элемент
        [e0, ~, ~, bary] = fem_find_element_bary(nodes, elems, centroids, elem_invA, elem_ok, p);
        
        if e0 == 0
            n_missed = n_missed + 1;
            fem.source_inject{s} = struct('node_idx', [], 'gradN_weighted', zeros(3,0));
            continue;
        end
        
        % Барицентрические координаты в E0
        % bary(j) = λ_j — близость к узлу j (и удалённость от грани напротив j)
        
        % Собираем элементы для инъекции:
        % E0 с весом w0, плюс соседи через грани
        inject_elems = e0;
        inject_weights = max(bary);  % вес E0 = max(λ)
        
        for j = 1:4
            nb = face_neighbor(e0, j);
            if nb > 0 && elem_ok(nb)
                % Вес соседа = λ_j (барицентрическая координата узла,
                % НАПРОТИВ которого расположена общая грань).
                % Чем ближе точка к грани (маленький λ_j) → малый вклад соседа.
                % Чем ближе к узлу j (большой λ_j) → точка далеко от этой грани,
                % но мы хотим обратное: большой вклад когда точка БЛИЗКО к грани.
                % Правильный вес: 1 - λ_j (= сумма λ остальных 3 узлов)
                w_nb = 1 - bary(j);
                % Экспоненциальное подавление далёких соседей
                w_nb = w_nb^2;
                if w_nb > 0.01  % порог для экономии
                    inject_elems(end+1) = nb;
                    inject_weights(end+1) = w_nb;
                end
            end
        end
        
        % Нормализация весов
        inject_weights = inject_weights / sum(inject_weights);
        
        % Собираем взвешенные gradN
        all_node_set = [];
        for ei = 1:length(inject_elems)
            all_node_set = [all_node_set, elems(inject_elems(ei), :)];
        end
        unique_nodes = unique(all_node_set);
        n_un = length(unique_nodes);
        weighted_gN = zeros(3, n_un);
        
        for ei = 1:length(inject_elems)
            e = inject_elems(ei);
            w = inject_weights(ei);
            gN_e = elem_gradN(:,:,e);
            e_nodes = elems(e, :);
            for j = 1:4
                pos = find(unique_nodes == e_nodes(j), 1);
                weighted_gN(:, pos) = weighted_gN(:, pos) + w * gN_e(:, j);
            end
        end
        
        fem.source_inject{s} = struct(...
            'node_idx', unique_nodes(:)', ...
            'gradN_weighted', weighted_gN);
    end
    
    if n_missed > 0
        fprintf('        FEM: %d/%d sources outside mesh\n', n_missed, n_sources);
    end
    
    % Обратная совместимость
    fem.dipole_d = h_mesh;
    fem.source_node_pairs = zeros(n_sources, 2);
end

%--------------------------------------------------------------------------
% MODULE: FEM solve (ПАТЧ FEM v3 — аналитический диполь)
%
% КРИТИЧЕСКОЕ ИЗМЕНЕНИЕ v3:
%   Вместо дипольных пар узлов (I+ на n_plus, I- на n_minus)
%   используем аналитическую инъекцию:
%     b_i = +Σ_sources (p_vec · ∇N_i(x_source))
%   где p_vec = sources_current(s) * orientation(s) — дипольный момент [A·m],
%   ∇N_i — градиент i-й функции формы в содержащем элементе.
%
%   Это математически эквивалентно решению:
%     ∫ σ∇φ·∇N_i dV = ∫ J_p·∇N_i dV,  J_p = p·δ(x-x_src)
%   где правая часть = p⃗·∇N_i(x_src) (положительный знак).
%--------------------------------------------------------------------------
function phi = solve_fem_for_sources(sources_current, solver_data, geom, ~, ea_idx)
    K = solver_data.fem_stiffness;
    n_nodes = size(K, 1);
    fem = solver_data.fem{ea_idx};
    basis_sources = solver_data.basis_sources;

    % --- Формируем вектор правой части (vertex-patch weighted injection) ---
    b = zeros(n_nodes, 1);

    nz = find(sources_current ~= 0);
    for k = 1:length(nz)
        s = nz(k);
        p_scalar = sources_current(s);   % скалярная амплитуда [A*m]
        
        % Дипольный момент = скаляр × ориентация
        orient = basis_sources(s).orientation(:);
        nu = norm(orient);
        if nu < 1e-12, orient = [0;0;1]; else, orient = orient / nu; end
        p_vec = p_scalar * orient;  % [A*m] вектор
        
        % Vertex-patch weighted injection:
        % b_i = Σ_over_patch_elems (vol_e/vol_total) * (p · gradN_e_i)
        % Предрасчитано: gradN_weighted содержит Σ (vol_e/vol_total) * gradN_e(:,j)
        
        inj = fem.source_inject{s};
        if isempty(inj.node_idx), continue; end
        
        % contrib(j) = p_vec' * gradN_weighted(:,j)
        contrib = inj.gradN_weighted' * p_vec;  % [n_patch_nodes × 1]
        
        for j = 1:length(inj.node_idx)
            ni = inj.node_idx(j);
            if ni > 0 && ni <= n_nodes
                b(ni) = b(ni) + contrib(j);
            end
        end
    end

    % --- Dirichlet BC: phi(ground_node) = 0 ---
    g = fem.ground_node;
    K_solve = K;
    K_solve(g, :) = 0;
    K_solve(:, g) = 0;
    K_solve(g, g) = 1;
    b(g) = 0;
    
    % Регуляризация (малая, для числовой устойчивости)
    K_solve = K_solve + 1e-12 * speye(n_nodes);

    % --- Решение (sparse) ---
    if n_nodes < 5000
        phi_nodes = K_solve \ b;
    else
        try
            L_ic = ichol(K_solve, struct('type', 'ict', 'droptol', 1e-4));
            [phi_nodes, flag] = pcg(K_solve, b, 1e-8, 2000, L_ic, L_ic');
            if flag ~= 0
                phi_nodes = K_solve \ b;
            end
        catch
            phi_nodes = K_solve \ b;
        end
    end

    % --- Считывание потенциалов на электродах ---
    % Площадное усреднение с Гауссовым весом (модель конечного электрода)
    elec_geom = geom.electrode_arrays{ea_idx};
    n_elec = elec_geom.n_electrodes;
    phi = zeros(n_elec, 1);
    nodes = solver_data.fem_mesh.nodes;

    sigma_elec = max(fem.electrode_radius, fem.h_mesh);
    search_radius = max(fem.electrode_radius * 2.0, fem.h_mesh * 3);
    
    for e = 1:n_elec
        c = elec_geom.positions_3d(:, e)';
        idx = fem_nodes_near_point_on_surface(nodes, fem.surface_nodes, c, search_radius);
        
        if isempty(idx)
            idx = fem_nearest_node(nodes, c);
            phi(e) = phi_nodes(idx);
        else
            dists = sqrt(sum((nodes(idx,:) - c).^2, 2));
            weights = exp(-dists.^2 / (2 * sigma_elec^2));
            weights = weights / sum(weights);
            phi(e) = sum(phi_nodes(idx) .* weights);
        end
    end
end

%--------------------------------------------------------------------------
% FEM HELPER: Find containing element with barycentric coordinates
%
% Для точки p находит тетраэдральный элемент и барицентрические координаты.
% Используется предрасчитанные invA для скорости.
%
% Выход:
%   elem_idx   — индекс найденного элемента (0 если не найден)
%   gradN      — 3×4 матрица градиентов функций формы
%   elem_nodes — [1×4] индексы узлов элемента
%   bary       — [1×4] барицентрические координаты (λ_1..λ_4)
%--------------------------------------------------------------------------
function [elem_idx, gradN, elem_nodes, bary] = fem_find_element_bary(nodes, elems, centroids, elem_invA, elem_ok, p)
    elem_idx = 0;
    gradN = zeros(3, 4);
    elem_nodes = zeros(1, 4);
    bary = zeros(1, 4);
    
    % Найти кандидатов по близости центроидов
    d2 = sum((centroids - p).^2, 2);
    [~, sorted_idx] = sort(d2);
    n_candidates = min(30, length(sorted_idx));
    
    for ci = 1:n_candidates
        ei = sorted_idx(ci);
        if ~elem_ok(ei), continue; end
        
        % Барицентрические координаты через предрасчитанный invA
        b_vec = [1, p(1), p(2), p(3)]';
        lambda = elem_invA(:,:,ei) * b_vec;
        
        if all(lambda >= -1e-6)
            elem_idx = ei;
            gradN = elem_invA(2:4,:,ei);  % строки 2:4 invA = gradN
            elem_nodes = elems(ei, :);
            bary = lambda';
            return;
        end
    end
    
    % Fallback: ближайший центроид
    for ci = 1:min(5, length(sorted_idx))
        ei = sorted_idx(ci);
        if ~elem_ok(ei), continue; end
        elem_idx = ei;
        gradN = elem_invA(2:4,:,ei);
        elem_nodes = elems(ei, :);
        b_vec = [1, p(1), p(2), p(3)]';
        bary = (elem_invA(:,:,ei) * b_vec)';
        return;
    end
end

%--------------------------------------------------------------------------
% FEM HELPER: find mesh nodes near a surface location (electrode footprint)
%--------------------------------------------------------------------------
function idx = fem_nodes_near_point_on_surface(nodes, surface_nodes, center, radius)
    if isempty(surface_nodes), idx = []; return; end
    cand = surface_nodes(:);
    d2 = sum((nodes(cand,:) - center).^2, 2);
    idx = cand(d2 <= radius^2);
    if isempty(idx), [~, k] = min(d2); idx = cand(k); end
end

%--------------------------------------------------------------------------
% FEM HELPER: nearest node index (Euclidean)
%--------------------------------------------------------------------------
function k = fem_nearest_node(nodes, p)
    d2 = sum((nodes - p).^2, 2);
    [~, k] = min(d2);
end

%--------------------------------------------------------------------------
% FEM HELPER: estimate characteristic mesh spacing h
%--------------------------------------------------------------------------
function h = fem_estimate_h(nodes)
    if size(nodes,1) < 5, h = 1e-3; return; end
    n = min(500, size(nodes,1));
    idx = randperm(size(nodes,1), n);
    P = nodes(idx,:);
    dmin = inf(n,1);
    for i=1:n
        d2 = sum((P - P(i,:)).^2, 2); d2(i)=inf;
        dmin(i)=sqrt(min(d2));
    end
    h = median(dmin(~isinf(dmin)));
    if ~isfinite(h) || h<=0, h = 1e-3; end
end


%% FRONTEND

%--------------------------------------------------------------------------
% FRONTEND: Electrode–skin contact impedance model
%
% Purpose:
%   - Применяет модель контакта (обычно RC/импеданс) к потенциалам на электродах.
%   - Это влияет на амплитуду/частотный отклик ДО усилителя.
%--------------------------------------------------------------------------
function v_e = apply_contact_impedance(phi_e, cfg, ea_cfg)
    if isempty(phi_e), v_e = phi_e; return; end
    fs = cfg.simulation.fs_internal;
    if isfield(ea_cfg, 'contact'), Rc = ea_cfg.contact.Rc; Cc = ea_cfg.contact.Cc;
    else, Rc = 100e3; Cc = 100e-9;
    end
    fc = min(max(1 / (2*pi*max(Rc, eps)*max(Cc, eps)), 0.1), fs/4);
    [b, a] = butter(1, fc/(fs/2), 'high');
    v_e = zeros(size(phi_e));
    for ch = 1:size(phi_e, 1), v_e(ch, :) = filtfilt(b, a, phi_e(ch, :)); end
end

%--------------------------------------------------------------------------
% FRONTEND: Spatial filter for differential derivations (ПАТЧ 9)
%
% Purpose:
%   - Реализует пространственные фильтры для HD-sEMG массивов
%   - Поддерживает SD (Single Differential), DD (Double Differential),
%     NDD (Normal Double Differential), BiTDD (Bi-Transverse Double Diff)
%   - Lee (2007): сравнение spatial filters для sEMG, ранжирование по SNR
%
% Использование:
%   Задайте cfg.electrode_arrays{ea}.spatial_filter = 'SD' | 'DD' | 'NDD'
%   Если не задан, используется legacy differential_pairs.
%
% Inputs:
%   v_e    : [n_electrodes × N_samples] потенциалы на электродах
%   ea_cfg : конфигурация массива электродов
%
% Output:
%   v_filt : [n_channels × N_samples] отфильтрованные каналы
%   labels : cell array с именами каналов (для визуализации)
%--------------------------------------------------------------------------
function [v_filt, labels] = apply_spatial_filter(v_e, ea_cfg)
    n_elec = size(v_e, 1);
    N_samp = size(v_e, 2);
    
    % Определяем тип фильтра
    if isfield(ea_cfg, 'spatial_filter') && ~isempty(ea_cfg.spatial_filter)
        filter_type = upper(ea_cfg.spatial_filter);
    else
        filter_type = 'NONE';
    end
    
    switch filter_type
        case 'SD'
            % Single Differential: y_i = v_{i+1} - v_i
            % Эквивалент первой пространственной производной
            n_ch = n_elec - 1;
            v_filt = zeros(n_ch, N_samp);
            labels = cell(n_ch, 1);
            for i = 1:n_ch
                v_filt(i, :) = v_e(i+1, :) - v_e(i, :);
                labels{i} = sprintf('SD_%d-%d', i+1, i);
            end
            
        case 'DD'
            % Double Differential: y_i = v_{i} - 2*v_{i+1} + v_{i+2}
            % Эквивалент второй пространственной производной (Laplacian 1D)
            % Лучше подавляет далёкие источники, чем SD (Lee, 2007)
            n_ch = n_elec - 2;
            if n_ch < 1
                fprintf('    WARN: DD requires >= 3 electrodes, falling back to SD\n');
                [v_filt, labels] = apply_spatial_filter_sd(v_e);
                return;
            end
            v_filt = zeros(n_ch, N_samp);
            labels = cell(n_ch, 1);
            for i = 1:n_ch
                v_filt(i, :) = v_e(i, :) - 2*v_e(i+1, :) + v_e(i+2, :);
                labels{i} = sprintf('DD_%d-%d-%d', i, i+1, i+2);
            end
            
        case 'NDD'
            % Normal Double Differential (Laplacian 2D)
            % Требует 2D массив: вычитает среднее 4 соседей
            % Для линейного массива fallback на DD
            if isfield(ea_cfg, 'grid_rows') && isfield(ea_cfg, 'grid_cols')
                n_rows = ea_cfg.grid_rows;
                n_cols = ea_cfg.grid_cols;
                if n_rows >= 3 && n_cols >= 3 && n_rows * n_cols == n_elec
                    % 2D Laplacian: y = v(i,j) - 0.25*(v(i-1,j)+v(i+1,j)+v(i,j-1)+v(i,j+1))
                    V = reshape(v_e, [n_rows, n_cols, N_samp]);
                    n_ch = (n_rows - 2) * (n_cols - 2);
                    v_filt = zeros(n_ch, N_samp);
                    labels = cell(n_ch, 1);
                    ch = 0;
                    for r = 2:n_rows-1
                        for c = 2:n_cols-1
                            ch = ch + 1;
                            v_center = squeeze(V(r, c, :))';
                            v_neighbors = squeeze(V(r-1,c,:))' + squeeze(V(r+1,c,:))' + ...
                                          squeeze(V(r,c-1,:))' + squeeze(V(r,c+1,:))';
                            v_filt(ch, :) = v_center - 0.25 * v_neighbors;
                            labels{ch} = sprintf('NDD_r%dc%d', r, c);
                        end
                    end
                else
                    fprintf('    WARN: NDD requires grid >= 3x3, falling back to DD\n');
                    [v_filt, labels] = apply_spatial_filter(setfield(ea_cfg, 'spatial_filter', 'DD'), ea_cfg);
                    v_filt_tmp = zeros(n_elec - 2, N_samp);
                    labels = cell(n_elec - 2, 1);
                    for i = 1:n_elec-2
                        v_filt_tmp(i,:) = v_e(i,:) - 2*v_e(i+1,:) + v_e(i+2,:);
                        labels{i} = sprintf('DD_%d-%d-%d', i, i+1, i+2);
                    end
                    v_filt = v_filt_tmp;
                end
            else
                % Линейный массив — используем DD
                n_ch = max(n_elec - 2, 1);
                v_filt = zeros(n_ch, N_samp);
                labels = cell(n_ch, 1);
                for i = 1:min(n_ch, n_elec-2)
                    v_filt(i, :) = v_e(i, :) - 2*v_e(i+1, :) + v_e(i+2, :);
                    labels{i} = sprintf('DD_%d-%d-%d', i, i+1, i+2);
                end
            end
            
        case 'IR'
            % Inverse Rectangle (BiTDD) — Disselhorst-Klug et al.
            % Для 2D массива: 4 угловых электрода - 4×центральный
            % Для линейного массива: v_{i-1} - 2*v_i + v_{i+1} (= DD)
            if isfield(ea_cfg, 'grid_rows') && isfield(ea_cfg, 'grid_cols')
                n_rows = ea_cfg.grid_rows;
                n_cols = ea_cfg.grid_cols;
                if n_rows >= 3 && n_cols >= 3 && n_rows * n_cols == n_elec
                    V = reshape(v_e, [n_rows, n_cols, N_samp]);
                    n_ch = (n_rows - 2) * (n_cols - 2);
                    v_filt = zeros(n_ch, N_samp);
                    labels = cell(n_ch, 1);
                    ch = 0;
                    for r = 2:n_rows-1
                        for c = 2:n_cols-1
                            ch = ch + 1;
                            % Сумма 4 угловых соседей - 4×центральный
                            v_corners = squeeze(V(r-1,c-1,:))' + squeeze(V(r-1,c+1,:))' + ...
                                        squeeze(V(r+1,c-1,:))' + squeeze(V(r+1,c+1,:))';
                            v_filt(ch, :) = v_corners - 4*squeeze(V(r,c,:))';
                            labels{ch} = sprintf('IR_r%dc%d', r, c);
                        end
                    end
                else
                    % Fallback to DD for linear array
                    n_ch = n_elec - 2;
                    v_filt = zeros(max(n_ch,1), N_samp);
                    labels = cell(max(n_ch,1), 1);
                    for i = 1:max(n_ch,1)
                        if i+2 <= n_elec
                            v_filt(i,:) = v_e(i,:) - 2*v_e(i+1,:) + v_e(i+2,:);
                        end
                        labels{i} = sprintf('DD_%d', i);
                    end
                end
            else
                n_ch = max(n_elec - 2, 1);
                v_filt = zeros(n_ch, N_samp);
                labels = cell(n_ch, 1);
                for i = 1:min(n_ch, n_elec-2)
                    v_filt(i,:) = v_e(i,:) - 2*v_e(i+1,:) + v_e(i+2,:);
                    labels{i} = sprintf('DD_%d', i);
                end
            end
            
        otherwise
            % NONE: без spatial filter, передаём без изменений
            v_filt = v_e;
            labels = cell(n_elec, 1);
            for i = 1:n_elec
                labels{i} = sprintf('mono_%d', i);
            end
    end
end

%--------------------------------------------------------------------------
% FRONTEND: Instrumentation amplifier model
%
% Purpose:
%   - Усиление + подавление синфазного сигнала (CMRR).
%   - Может добавлять эквивалентный входной шум усилителя.
%--------------------------------------------------------------------------
function y = apply_instrumentation_amplifier(v_e, ~, ea_cfg)
    if isempty(v_e), y = v_e; return; end
    amp = ea_cfg.amplifier;
    G = amp.gain;
    alpha = 10^(-amp.cmrr_db/20);
    
    if isfield(ea_cfg, 'differential_pairs') && ~isempty(ea_cfg.differential_pairs)
        n_pairs = size(ea_cfg.differential_pairs, 1);
        y = zeros(n_pairs, size(v_e, 2));
        for p = 1:n_pairs
            idx_plus = ea_cfg.differential_pairs(p, 1);
            idx_minus = ea_cfg.differential_pairs(p, 2);
            Vdiff = v_e(idx_plus, :) - v_e(idx_minus, :);
            Vcm = (v_e(idx_plus, :) + v_e(idx_minus, :)) / 2;
            % Reference for common-mode:
            % - If explicit ground electrode trace is provided, reference CM to it.
            % - Otherwise (legacy), reference to configured reference electrode inside v_e.
            if ~isempty(v_gnd)
                Vcm = Vcm - v_gnd;
            elseif isfield(ea_cfg, 'reference_electrode') && ea_cfg.reference_electrode > 0
                Vcm = Vcm - v_e(ea_cfg.reference_electrode, :);
            end
y(p, :) = G * (Vdiff + alpha * Vcm);
        end
    elseif size(v_e, 1) < 2
        % Одноканальный вход (после spatial filter или моно) — только усиление
        y = G * v_e;
    else
        Vdiff = v_e(1, :) - v_e(end, :);
        Vcm = (v_e(1, :) + v_e(end, :)) / 2;
        if ~isempty(v_gnd)
            Vcm = Vcm - v_gnd;
        elseif isfield(ea_cfg, 'reference_electrode') && ea_cfg.reference_electrode > 0
            Vcm = Vcm - v_e(ea_cfg.reference_electrode, :);
        end
y = G * (Vdiff + alpha * Vcm);
    end
end

%--------------------------------------------------------------------------
% FRONTEND: Analog filtering (HP/LP/Notch)
%
% Purpose:
%   - Применяет полосовые ограничения и сетевой notch (если задан).
%   - Делается перед децимацией, чтобы избежать алиасинга.
%--------------------------------------------------------------------------
function emg = apply_analog_filters(emg_amplified, cfg, ea_cfg)
    fs = cfg.simulation.fs_internal;
    amp = ea_cfg.amplifier;
    
    [b_hp, a_hp] = butter(2, amp.highpass_cutoff/(fs/2), 'high');
    emg = filtfilt(b_hp, a_hp, emg_amplified')';
    
    [b_lp, a_lp] = butter(4, amp.lowpass_cutoff/(fs/2), 'low');
    emg = filtfilt(b_lp, a_lp, emg')';
    
    [b_notch, a_notch] = iirnotch(amp.notch_freq/(fs/2), amp.notch_bw/(fs/2));
    emg = filtfilt(b_notch, a_notch, emg')';
end

%--------------------------------------------------------------------------
% FRONTEND: Add measurement noise (sensor + ADC)
%
% Purpose:
%   - Добавляет шум измерения на выходе (после децимации).
%   - Используется для приближения к реальному железу.
%--------------------------------------------------------------------------
function emg = add_measurement_noise(emg_clean, cfg, ea_cfg)
    fs = cfg.simulation.fs_output;
    noise_power = ea_cfg.amplifier.noise_density * sqrt(fs);
    emg = emg_clean + noise_power * randn(size(emg_clean));
end

%--------------------------------------------------------------------------
% FRONTEND v2: Compute ground electrode potential
%
% Purpose:
%   - Вычисляет потенциал на электроде земли для данного массива.
%   - Если ground_electrode.enabled = true, используется интерполяция
%     по ближайшим электродам массива (приближение).
%   - Иначе — средний потенциал всех электродов (далёкая земля).
%
% Backward compatibility:
%   Когда ground_electrode.enabled = false, результат ≈ mean(phi_raw),
%   что эквивалентно неявной далёкой земле в оригинальном коде.
%--------------------------------------------------------------------------
function phi_gnd = compute_ground_potential(phi_raw, ea_cfg, geom)
    if isempty(phi_raw)
        phi_gnd = zeros(1, 0);
        return;
    end
    
    ge = ea_cfg.ground_electrode;
    
    if ge.enabled
        % Земля в произвольной точке на коже — интерполяция по электродам массива
        R_skin = geom.radii.skin;
        gnd_angle_rad = ge.angle * pi / 180;
        gnd_pos = [R_skin * cos(gnd_angle_rad); ...
                   R_skin * sin(gnd_angle_rad); ...
                   ge.position_z];
        
        n_elec = size(phi_raw, 1);
        z0 = ea_cfg.position_z;
        spacing = ea_cfg.spacing;
        base_angle = ea_cfg.angle * pi / 180;
        array_rot = 0;
        if isfield(ea_cfg, 'array_rotation')
            array_rot = ea_cfg.array_rotation * pi / 180;
        end
        
        elec_positions = zeros(3, n_elec);
        for e = 1:n_elec
            offset = (e - (n_elec + 1)/2) * spacing;
            dz = offset * cos(array_rot);
            d_tang = offset * sin(array_rot);
            elec_positions(:, e) = [...
                R_skin * cos(base_angle + d_tang/R_skin); ...
                R_skin * sin(base_angle + d_tang/R_skin); ...
                z0 + dz];
        end
        
        % Взвешенная интерполяция (обратные квадраты расстояний)
        dists = sqrt(sum((elec_positions - gnd_pos).^2, 1));
        dists = max(dists, 1e-6);
        weights = 1 ./ (dists.^2);
        weights = weights / sum(weights);
        
        phi_gnd = weights * phi_raw;  % [1 × N_samples]
    else
        % Далёкая земля — средний потенциал всех электродов
        phi_gnd = mean(phi_raw, 1);
    end
end

%--------------------------------------------------------------------------
% FRONTEND v2: Объединение земель нескольких датчиков
%
% Purpose:
%   - Когда земли нескольких датчиков физически соединены проводником,
%     их потенциалы выравниваются (взвешенное среднее по проводимостям).
%
% Backward compatibility:
%   Когда ground_merge.enabled = false, функция ничего не делает.
%--------------------------------------------------------------------------
function phi_ground = apply_ground_merge(phi_ground, cfg)
    if ~isfield(cfg, 'interference') || ~isfield(cfg.interference, 'ground_merge')
        return;
    end
    gm = cfg.interference.ground_merge;
    if ~gm.enabled || isempty(gm.groups)
        return;
    end
    
    n_arrays = numel(phi_ground);
    
    for g = 1:numel(gm.groups)
        group_idx = gm.groups{g};
        group_idx = group_idx(group_idx >= 1 & group_idx <= n_arrays);
        if numel(group_idx) < 2, continue; end
        
        N_samp = size(phi_ground{group_idx(1)}, 2);
        
        % Взвешенное усреднение по проводимостям (1/Rc)
        phi_sum = zeros(1, N_samp);
        total_G = 0;
        for k = 1:numel(group_idx)
            idx = group_idx(k);
            ea = cfg.electrode_arrays{idx};
            Rc_gnd = ea.contact.Rc;
            if ea.ground_electrode.enabled
                Rc_gnd = ea.ground_electrode.Rc;
            end
            if ea.contact_imbalance.enabled
                Rc_gnd = Rc_gnd * ea.contact_imbalance.Rc_ground_factor;
            end
            G_k = 1 / max(Rc_gnd, 1);
            phi_sum = phi_sum + G_k * phi_ground{idx};
            total_G = total_G + G_k;
        end
        
        phi_merged = phi_sum / total_G;
        for k = 1:numel(group_idx)
            phi_ground{group_idx(k)} = phi_merged;
        end
    end
end

%--------------------------------------------------------------------------
% FRONTEND v2: Сетевая помеха (power line interference)
%
% Purpose:
%   - Имитирует наводку 50/60 Гц от электросети на поверхности кожи.
%   - Тело — антенна: помеха приходит как синфазный сигнал.
%   - Из-за различий в расстоянии до источника — слабые вариации
%     амплитуды и фазы между электродами → утечка в дифф. канал.
%   - Добавляет DC-смещение (half-cell potential).
%
% Backward compatibility:
%   Когда mains.enabled = false, ничего не делает.
%--------------------------------------------------------------------------
function [phi_raw, phi_ground] = apply_mains_interference(phi_raw, phi_ground, cfg, t)
    mc = cfg.interference.mains;
    
    f0 = mc.frequency;
    V_cm = mc.amplitude_Vp;
    n_harm = mc.n_harmonics;
    harm_decay = mc.harmonic_decay;
    dc_base = mc.dc_offset_V;
    dc_spread = mc.dc_offset_spread_V;
    phase_noise = mc.phase_noise_deg * pi / 180;
    amp_noise = mc.amplitude_noise;
    
    n_arrays = numel(phi_raw);
    
    % Фиксируем seed для воспроизводимости помехи
    rng_state = rng;
    rng(42, 'twister');
    
    phi0 = 2*pi*rand();  % начальная фаза
    
    % Предрасчёт гармоник (для переиспользования)
    harm_orders = 2*(1:n_harm) + 1;  % 3, 5, 7...
    harm_amps = V_cm * harm_decay .^ (1:n_harm);
    harm_phases = 2*pi*rand(1, n_harm);
    
    for ea = 1:n_arrays
        n_elec = size(phi_raw{ea}, 1);
        
        for e = 1:n_elec
            % Индивидуальная вариация для каждого электрода
            d_phase = phase_noise * randn();
            d_amp = 1 + amp_noise * randn();
            dc_elec = dc_base + dc_spread * randn();
            
            v_mains = d_amp * V_cm * sin(2*pi*f0*t + phi0 + d_phase);
            for k = 1:n_harm
                v_mains = v_mains + d_amp * harm_amps(k) * ...
                    sin(2*pi*harm_orders(k)*f0*t + harm_phases(k) + d_phase*harm_orders(k));
            end
            
            phi_raw{ea}(e, :) = phi_raw{ea}(e, :) + v_mains + dc_elec;
        end
        
        % Помеха на земле
        d_phase_g = phase_noise * randn();
        d_amp_g = 1 + amp_noise * randn();
        dc_gnd = dc_base + dc_spread * randn();
        
        v_mains_g = d_amp_g * V_cm * sin(2*pi*f0*t + phi0 + d_phase_g);
        for k = 1:n_harm
            v_mains_g = v_mains_g + d_amp_g * harm_amps(k) * ...
                sin(2*pi*harm_orders(k)*f0*t + harm_phases(k) + d_phase_g*harm_orders(k));
        end
        
        phi_ground{ea} = phi_ground{ea} + v_mains_g + dc_gnd;
    end
    
    rng(rng_state);  % восстанавливаем ГСЧ
end

%--------------------------------------------------------------------------
% FRONTEND v2: Electrode–skin contact impedance (модель Рандлса + Z_in)
%
% Эквивалентная схема контакта (модель Рандлса):
%
%   φ_tissue ─── Rs ───┬── Rc ──┬─── узел INA
%                       │        │         │
%                       └── Cc ──┘        Z_in
%                                          │
%                                         GND
%
%   Rs = последовательное сопр-е (электролит, гель, кабель)
%        НЕ шунтируется ёмкостью → действует на ВСЕХ частотах!
%   Rc || Cc = параллельная RC (charge transfer + двойной слой)
%
%   Z_contact(s) = Rs + Rc/(1+sτ),  τ = Rc·Cc
%
%   Делитель: H(s) = Z_in / (Z_contact(s) + Z_in)
%     = Z_in·(1+sτ) / ((Rs+Rc+Z_in) + sτ·(Rs+Z_in))
%
%     DC:  H(0) = Z_in / (Rs+Rc+Z_in)      — полное ослабление
%     HF:  H(∞) = Z_in / (Rs+Z_in)          — Rs остаётся!
%
%   Механизм CM→DM: разные Rs/Rc/Cc у электродов → разные H_k(jω).
%   Используется каузальный filter для сохранения фаз между каналами.
%--------------------------------------------------------------------------
function [v_e, v_gnd] = apply_contact_impedance_v2(phi_e, phi_gnd, cfg, ea_cfg)
    if nargin < 2, phi_gnd = []; end
    if isempty(phi_e), v_e = phi_e; v_gnd = phi_gnd; return; end
    
    fs = cfg.simulation.fs_internal;
    n_elec = size(phi_e, 1);
    N_samp = size(phi_e, 2);
    
    % Базовые Rs, Rc, Cc
    if isfield(ea_cfg, 'contact')
        Rs_base = getf_local(ea_cfg.contact, 'Rs', 0);  % по умолчанию 0
        Rc_base = ea_cfg.contact.Rc;
        Cc_base = ea_cfg.contact.Cc;
    else
        Rs_base = 0; Rc_base = 100e3; Cc_base = 100e-9;
    end
    
    % Входное сопротивление INA
    if isfield(ea_cfg, 'amplifier') && isfield(ea_cfg.amplifier, 'input_impedance') ...
            && ea_cfg.amplifier.input_impedance > 0
        Z_in = ea_cfg.amplifier.input_impedance;
    else
        Z_in = 200e6;
    end
    
    % Дисбаланс
    imb_on = isfield(ea_cfg, 'contact_imbalance') && ea_cfg.contact_imbalance.enabled;
    
    % Warmup: 5τ_max
    tau_max = Rc_base * Cc_base;
    if imb_on
        for ch = 1:min(n_elec, numel(ea_cfg.contact_imbalance.Rc_factors))
            tau_ch = Rc_base * ea_cfg.contact_imbalance.Rc_factors(ch) * ...
                     Cc_base * ea_cfg.contact_imbalance.Cc_factors(ch);
            tau_max = max(tau_max, tau_ch);
        end
    end
    % Учитываем τ земли (если задано)
    if imb_on
        imb = ea_cfg.contact_imbalance;
        if isfield(imb,'Rc_ground_factor') && isfield(imb,'Cc_ground_factor')
            % Use explicit ground electrode Rc/Cc if available (else fall back to base contact)
            Rc_g0 = Rc_base; Cc_g0 = Cc_base;
            if isfield(ea_cfg,'ground_electrode')
                ge = ea_cfg.ground_electrode;
                if isfield(ge,'Rc') && ~isempty(ge.Rc) && ge.Rc>0, Rc_g0 = ge.Rc; end
                if isfield(ge,'Cc') && ~isempty(ge.Cc) && ge.Cc>0, Cc_g0 = ge.Cc; end
            end
            tau_g = Rc_g0 * getf_local(imb,'Rc_ground_factor',1.0) * Cc_g0 * getf_local(imb,'Cc_ground_factor',1.0);
            tau_max = max(tau_max, tau_g);
        end
    end
    n_warmup = min(round(5 * tau_max * fs), N_samp);
    
    v_e = zeros(n_elec, N_samp);
    c_blt = 2 * fs;
    
    for ch = 1:n_elec
        if imb_on && ch <= length(ea_cfg.contact_imbalance.Rc_factors)
            Rc_ch = Rc_base * ea_cfg.contact_imbalance.Rc_factors(ch);
            Cc_ch = Cc_base * ea_cfg.contact_imbalance.Cc_factors(ch);
            % Rs_factors (если есть)
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
        
        % H(s) = Z_in·(1+sτ) / ((Rs+Rc+Z_in) + sτ·(Rs+Z_in))
        b1_s = Z_in * tau;
        b0_s = Z_in;
        a1_s = tau * (Rs_ch + Z_in);
        a0_s = Rs_ch + Rc_ch + Z_in;
        
        % Билинейная трансформация
        B = [b1_s*c_blt + b0_s, -b1_s*c_blt + b0_s];
        A = [a1_s*c_blt + a0_s, -a1_s*c_blt + a0_s];
        B = B / A(1);
        A = A / A(1);
        
        x_ch = phi_e(ch, :);
        warmup = x_ch(1) * ones(1, n_warmup);
        x_padded = [warmup, x_ch];
        y_padded = filter(B, A, x_padded);
        v_e(ch, :) = y_padded(n_warmup+1 : end);
    end

    % --- Земля / reference electrode (отдельная контактная цепь) ---
    % phi_gnd ожидается как [1 × N_samples] или [N_samples × 1]
    if isempty(phi_gnd)
        v_gnd = zeros(1, N_samp);
    else
        if size(phi_gnd,1) > 1 && size(phi_gnd,2) == 1
            phi_gnd = phi_gnd.';  % в строку
        end
        % Параметры земли: базовые, плюс (опционально) множители дисбаланса
        % Base parameters for ground electrode contact path:
        % - Prefer explicit ea_cfg.ground_electrode.(Rc,Cc) if present
        % - Otherwise fall back to the main electrode contact (legacy)
        Rc_g = Rc_base;
        Cc_g = Cc_base;
        Rs_g = Rs_base;
        if isfield(ea_cfg, 'ground_electrode')
            ge = ea_cfg.ground_electrode;
            if isfield(ge, 'Rc') && ~isempty(ge.Rc) && ge.Rc > 0, Rc_g = ge.Rc; end
            if isfield(ge, 'Cc') && ~isempty(ge.Cc) && ge.Cc > 0, Cc_g = ge.Cc; end
            % No explicit Rs in cfg.ground_electrode by default; keep Rs_g as base unless user adds it.
            if isfield(ge, 'Rs') && ~isempty(ge.Rs) && ge.Rs >= 0, Rs_g = ge.Rs; end
        end
        if imb_on
            imb = ea_cfg.contact_imbalance;
            if isfield(imb, 'Rc_ground_factor') && ~isempty(imb.Rc_ground_factor)
                Rc_g = Rc_base * imb.Rc_ground_factor;
            end
            if isfield(imb, 'Cc_ground_factor') && ~isempty(imb.Cc_ground_factor)
                Cc_g = Cc_base * imb.Cc_ground_factor;
            end
            if isfield(imb, 'Rs_ground_factor') && ~isempty(imb.Rs_ground_factor)
                Rs_g = Rs_base * imb.Rs_ground_factor;
            end
        end

        tau_g = Rc_g * Cc_g;
        % H(s) = Z_in·(1+sτ) / ((Rs+Rc+Z_in) + sτ·(Rs+Z_in))
        b1_s = Z_in * tau_g;
        b0_s = Z_in;
        a1_s = tau_g * (Rs_g + Z_in);
        a0_s = Rs_g + Rc_g + Z_in;

        % Билинейная трансформация
        B = [b1_s*c_blt + b0_s, -b1_s*c_blt + b0_s];
        A = [a1_s*c_blt + a0_s, -a1_s*c_blt + a0_s];
        B = B / A(1);
        A = A / A(1);

        % Warmup для земли: используем тот же n_warmup (по tau_max)
        warmup = phi_gnd(1) * ones(1, n_warmup);
        x_padded = [warmup, phi_gnd(:).'];  % гарантируем строку
        y_padded = filter(B, A, x_padded);
        v_gnd = y_padded(n_warmup+1 : end);
    end

end

function v = getf_local(S, f, def)
    if isfield(S, f), v = S.(f); else, v = def; end
end

%--------------------------------------------------------------------------
% FRONTEND v2: Instrumentation amplifier (INA)
%
% Модель по стандартной формуле CMRR деградации:
%   v_out = G · (V_diff + α_eff · V_cm)
%
%   α_eff = α_amp + ΔZ_source / (2·Z_cm_in)
%
%   Два механизма CM→DM конверсии суммируются:
%     1) α_amp = 10^(-CMRR_dB/20) — внутренняя утечка INA
%     2) α_imb = ΔZ/(2·Z_cm_in) — деградация CMRR от разницы
%        импедансов контакта E1 и E3. Синфазный ток через Z_cm_in
%        создаёт разные падения на разных Z_source.
%
%   Z_cm_in = input_impedance (настраивается, типично 10-200 МОм
%   с учётом паразитных ёмкостей и кабеля)
%
%   ΔZ оценивается на частоте сетевой помехи (50 Гц).
%--------------------------------------------------------------------------
function y = apply_instrumentation_amplifier_v2(v_e, v_gnd, ea_cfg)
    if nargin < 2, v_gnd = []; end
    if isempty(v_e), y = v_e; return; end
    amp = ea_cfg.amplifier;
    G = amp.gain;
    alpha_amp = 10^(-amp.cmrr_db/20);
    
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
            omega = 2*pi*50;  % оценка при 50 Гц
            Rc1 = Rc_base * imb.Rc_factors(1);
            Rc3 = Rc_base * imb.Rc_factors(3);
            Cc1 = Cc_base * imb.Cc_factors(1);
            Cc3 = Cc_base * imb.Cc_factors(min(3,end));
            % Z_c = Rc/(1+jωRcCc)
            Z1 = Rc1 / (1 + 1i*omega*Rc1*Cc1);
            Z3 = Rc3 / (1 + 1i*omega*Rc3*Cc3);
            dZ = abs(Z1 - Z3);
            alpha_imb = dZ / (2 * Z_cm_in);
        end
    end
    
    alpha = alpha_amp + alpha_imb;
    
    if isfield(ea_cfg, 'differential_pairs') && ~isempty(ea_cfg.differential_pairs)
        n_pairs = size(ea_cfg.differential_pairs, 1);
        y = zeros(n_pairs, size(v_e, 2));
        for p = 1:n_pairs
            idx_plus = ea_cfg.differential_pairs(p, 1);
            idx_minus = ea_cfg.differential_pairs(p, 2);
            Vdiff = v_e(idx_plus, :) - v_e(idx_minus, :);
            Vcm = (v_e(idx_plus, :) + v_e(idx_minus, :)) / 2;
            if ~isempty(v_gnd)
                Vcm = Vcm - v_gnd;
            end
            if isfield(ea_cfg, 'reference_electrode') && ea_cfg.reference_electrode > 0
                Vcm = Vcm - v_e(ea_cfg.reference_electrode, :);
            end
            y(p, :) = G * (Vdiff + alpha * Vcm);
        end
    elseif size(v_e, 1) < 2
        y = G * v_e;
    else
        Vdiff = v_e(1, :) - v_e(end, :);
        Vcm = (v_e(1, :) + v_e(end, :)) / 2;
        if ~isempty(v_gnd)
            Vcm = Vcm - v_gnd;
        end
        y = G * (Vdiff + alpha * Vcm);
    end
end

%--------------------------------------------------------------------------
% IO: Save results to disk
%
% Purpose:
%   - Сохраняет results и/или инкрементальные куски в cfg.save_path.
%   - Формат и состав сохраняемых полей определяются внутри.
%--------------------------------------------------------------------------
function save_simulation_results(results, cfg)
    main_data_file = fullfile(cfg.save_path, 'emg_simulation_full.mat');
    save(main_data_file, 'results', '-v7.3');
    fprintf('      Full data saved: %s\n', main_data_file);
    
    compact_results = struct();
    compact_results.config = results.config;
    compact_results.time = results.time;
    compact_results.time_full = results.time_full;
    compact_results.force = results.force;
    compact_results.force_decimated = results.force_decimated;  % ИСПРАВЛЕНИЕ: добавлено
    compact_results.force_reference = results.force_reference;
    compact_results.force_reference_decimated = results.force_reference_decimated;  % ИСПРАВЛЕНИЕ: добавлено
    compact_results.phi_electrodes_raw = results.phi_electrodes_raw;
    compact_results.phi_electrodes_bio = results.phi_electrodes_bio;
    compact_results.phi_ground = results.phi_ground;
    compact_results.phi_ground_bio = results.phi_ground_bio;
    compact_results.emg = results.emg;
    compact_results.neural_drive = results.neural_drive_history;
    compact_results.spike_history = results.spike_history;
    
    compact_data_file = fullfile(cfg.save_path, 'emg_simulation_compact.mat');
    save(compact_data_file, 'compact_results', '-v7.3');
    fprintf('      Compact data saved: %s\n', compact_data_file);
    
    % === ИСПРАВЛЕНИЕ: Сохранение силы мышцы в отдельный файл ===
    force_folder = fullfile(cfg.save_path, 'force_signals');
    if ~exist(force_folder, 'dir'), mkdir(force_folder); end
    
    force_data = struct();
    force_data.time = results.time;                              % Временная сетка (fs_output)
    force_data.time_full = results.time_full;                    % Полная временная сетка (fs_internal)
    force_data.force = results.force;                            % Сила на fs_internal [n_muscles x N]
    force_data.force_decimated = results.force_decimated;        % Сила на fs_output [n_muscles x N_out]
    force_data.force_reference = results.force_reference;        % Целевая сила на fs_internal
    force_data.force_reference_decimated = results.force_reference_decimated;  % Целевая сила на fs_output
    force_data.fs_internal = results.config.simulation.fs_internal;
    force_data.fs_output = results.config.simulation.fs_output;
    force_data.muscle_names = cellfun(@(m) m.name, results.config.muscles, 'UniformOutput', false);
    force_data.n_muscles = length(results.config.muscles);
    
    force_file = fullfile(force_folder, 'force_signals.mat');
    save(force_file, 'force_data');
    fprintf('      Force data saved: %s\n', force_file);
    
    % Отдельные файлы для каждой мышцы (аналогично EMG)
    for m = 1:length(results.config.muscles)
        muscle_force = struct();
        muscle_force.time = results.time;
        muscle_force.time_full = results.time_full;
        muscle_force.force = results.force(m, :);
        muscle_force.force_decimated = results.force_decimated(m, :);
        muscle_force.force_reference = results.force_reference(m, :);
        muscle_force.force_reference_decimated = results.force_reference_decimated(m, :);
        muscle_force.muscle_name = results.config.muscles{m}.name;
        muscle_force.muscle_config = results.config.muscles{m};
        muscle_force.fs_internal = results.config.simulation.fs_internal;
        muscle_force.fs_output = results.config.simulation.fs_output;
        
        muscle_file = fullfile(force_folder, sprintf('force_muscle_%d_%s.mat', m, results.config.muscles{m}.name));
        save(muscle_file, 'muscle_force');
        fprintf('      Muscle %d force saved: %s\n', m, muscle_file);
    end
    
    emg_folder = fullfile(cfg.save_path, 'emg_signals');
    if ~exist(emg_folder, 'dir'), mkdir(emg_folder); end
    
    for ea = 1:length(results.emg)
        emg_data = struct();
        emg_data.time = results.time;
        emg_data.signal = results.emg{ea};
        emg_data.electrode_array = results.config.electrode_arrays{ea};
        emg_data.fs = results.config.simulation.fs_output;
        emg_file = fullfile(emg_folder, sprintf('emg_array_%d_%s.mat', ea, results.config.electrode_arrays{ea}.name));
        save(emg_file, 'emg_data');
        fprintf('      EMG signal saved: %s\n', emg_file);
    end
    
    meta_file = fullfile(cfg.save_path, 'simulation_metadata.txt');
    fid = fopen(meta_file, 'w');
    fprintf(fid, 'EMG SIMULATION METADATA\n======================\n\n');
    fprintf(fid, 'Date: %s\n', datestr(now));
    fprintf(fid, 'Duration: %.2f s\n', cfg.simulation.duration);
    fprintf(fid, 'Sampling rate: %d Hz (internal), %d Hz (output)\n', cfg.simulation.fs_internal, cfg.simulation.fs_output);
    fprintf(fid, 'Solver mode: %s\n\n', cfg.simulation.solver_mode);
    fprintf(fid, 'Muscles: %d\n', length(cfg.muscles));
    for m = 1:length(cfg.muscles)
        fprintf(fid, '  %d. %s: %d MUs, sigma=%.1f N/cm², area=%.2f cm²\n', m, cfg.muscles{m}.name, ...
            cfg.muscles{m}.n_motor_units, cfg.muscles{m}.sigma, cfg.muscles{m}.cross_section_area * 1e4);
    end
    fprintf(fid, '\nElectrode arrays: %d\n', length(cfg.electrode_arrays));
    for ea = 1:length(cfg.electrode_arrays)
        fprintf(fid, '  %d. %s: %d electrodes\n', ea, cfg.electrode_arrays{ea}.name, cfg.electrode_arrays{ea}.n_electrodes);
    end
    fprintf(fid, '\nComputation time: %.2f s\n', sum(struct2array(results.computation_time)));
    fclose(fid);
    fprintf('      Metadata saved: %s\n', meta_file);
end

%--------------------------------------------------------------------------
% HELPER: Initialize MUAP Library
%--------------------------------------------------------------------------
function lib = initialize_muap_library(cfg, geom)
% initialize_muap_library - Инициализирует библиотеку предрасчитанных MUAP
%
% Пытается загрузить из файла, если не получается - предрасчитывает.

    lib = [];
    
    % Проверяем наличие класса MUAPLibrary
    if exist('MUAPLibrary', 'class') ~= 8
        warning('EMG:MUAPLibrary', 'MUAPLibrary class not found. Library disabled.');
        return;
    end
    
    try
        lib = MUAPLibrary();
        lib.setCfg(cfg);
        
        % Настраиваем сетки из cfg
        if isfield(cfg.muap_library, 'n_depth_points')
            % Получаем радиус мышечной области из geom.radii или cfg.geometry
            if isfield(geom, 'radii') && isfield(geom.radii, 'muscle')
                R_muscle = geom.radii.muscle;
            elseif isfield(cfg, 'geometry') && isfield(cfg.geometry, 'radius_outer')
                R_muscle = cfg.geometry.radius_outer * 0.7;  % Примерная оценка
            else
                R_muscle = 0.035;  % По умолчанию 35 мм
            end
            depth_range = [0.005, R_muscle];
            lib.depth_grid = linspace(depth_range(1), depth_range(2), cfg.muap_library.n_depth_points);
        end
        
        if isfield(cfg.muap_library, 'n_cv_points')
            cv_range = [2.5, 6.0];
            if isfield(cfg, 'fibers') && isfield(cfg.fibers, 'cv_range')
                cv_range = [min(cfg.fibers.cv_range)*0.8, max(cfg.fibers.cv_range)*1.2];
            end
            lib.cv_grid = linspace(cv_range(1), cv_range(2), cfg.muap_library.n_cv_points);
        end
        
        if isfield(cfg.muap_library, 'n_fat_points')
            fat_range = [0.002, 0.008];
            if isfield(cfg.geometry, 'fat_thickness')
                fat_nominal = cfg.geometry.fat_thickness;
                fat_range = [fat_nominal * 0.5, fat_nominal * 2.0];
            end
            lib.fat_thickness_grid = linspace(fat_range(1), fat_range(2), cfg.muap_library.n_fat_points);
        end
        
        % Пытаемся загрузить из файла
        cache_loaded = false;
        if isfield(cfg.muap_library, 'cache_file') && ~isempty(cfg.muap_library.cache_file)
            if exist(cfg.muap_library.cache_file, 'file')
                cache_loaded = lib.load(cfg.muap_library.cache_file);
                
                % Проверяем валидность кеша
                if cache_loaded && ~lib.isValid(cfg)
                    fprintf('        MUAP library cache invalid, recomputing...\n');
                    cache_loaded = false;
                    lib.invalidate();
                end
            end
        end
        
        % Если не загружен - предрасчитываем
        if ~cache_loaded && cfg.muap_library.auto_precompute
            fprintf('        Precomputing MUAP library...\n');
            lib.verbose = true;
            lib.precompute(struct('progress', true));
            
            % Сохраняем если указан путь
            if cfg.muap_library.save_after_compute && isfield(cfg.muap_library, 'cache_file') && ~isempty(cfg.muap_library.cache_file)
                lib.save(cfg.muap_library.cache_file);
            elseif cfg.muap_library.save_after_compute
                % Автоматический путь
                default_cache_file = fullfile(cfg.save_path, 'muap_library_cache.mat');
                lib.save(default_cache_file);
            end
        end
        
    catch e
        warning('EMG:MUAPLibrary', 'Failed to initialize MUAP library: %s', e.message);
        lib = [];
    end
end

%--------------------------------------------------------------------------
% HELPER: Get source depth (distance from skin surface)
%--------------------------------------------------------------------------
function depth = get_source_depth(source_position, geom)
% get_source_depth - Вычисляет глубину источника от поверхности кожи
%
% ВХОД:
%   source_position - [x, y, z] позиция источника
%   geom - структура геометрии
%
% ВЫХОД:
%   depth - расстояние до поверхности [м]

    x = source_position(1);
    y = source_position(2);
    
    r_source = sqrt(x^2 + y^2);
    R_skin = geom.radii.skin;
    
    depth = max(0, R_skin - r_source);
end