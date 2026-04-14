function cfg = emg_configurator(varargin)
% EMG_CONFIGURATOR - GUI для подготовки конфигурации EMG симулятора.
% -------------------------------------------------------------------------
% Создаёт и редактирует cfg-структуру, совместимую с emg_simulation_core(cfg).
% Поддерживает:
%   - Геометрию сечения (кости/мышцы/слои кожи-жира-фасции/внешний радиус)
%   - Настройку каждой активной мышцы (имя, позиция, площадь, sigma, число ДЕ, фасция, профиль силы)
%   - Настройку распределений ДЕ (пространственных и по характеристикам)
%   - Настройку набора датчиков (имя, electrode_arrays) и их параметров
%   - Запуск симуляции с текущей конфигурацией
%   - Сохранение/загрузка cfg (*.mat)
%
% ВЫЗОВ:
%   cfg = emg_configurator();             % интерактивно, возвращает cfg после закрытия
%   emg_configurator('save', 'cfg.mat');  % откроет GUI и предложит сохранить
%
% ВЕРСИЯ: 2.1 - Исправлен контроллер ДЕ, добавлены настройки распределений
% Автор: Kotel project / EMG framework
% -------------------------------------------------------------------------

    % --- init cfg
    cfg = cfg_default();

    % --- optional: load initial cfg if path provided
    if nargin >= 1 && ischar(varargin{1}) && exist(varargin{1}, 'file')
        S = load(varargin{1});
        if isfield(S,'cfg'), cfg = S.cfg;
        elseif isfield(S,'config'), cfg = S.config;
        end
        cfg = validate_cfg_for_core(cfg);
    end

    % --- main hub window
    hub = uifigure('Name','EMG Configurator (hub)','Position',[120 120 520 420]);

    gl = uigridlayout(hub,[10 2]);
    gl.RowHeight = {32,32,32,32,32,32,32,32,'1x',36};
    gl.ColumnWidth = {'1x','1x'};

    lbl = uilabel(gl,'Text','Конфигурация EMG симулятора','FontWeight','bold','FontSize',14);
    lbl.Layout.Row = 1; lbl.Layout.Column = [1 2];

    btnGeom = uibutton(gl,'Text','Окно 1: Сечение / геометрия', ...
        'ButtonPushedFcn',@(s,e)open_geometry_editor());
    btnGeom.Layout.Row = 2; btnGeom.Layout.Column = [1 2];

    btnTargets = uibutton(gl,'Text','Окно 2: Целевые силы мышц', ...
        'ButtonPushedFcn',@(s,e)open_targets_editor());
    btnTargets.Layout.Row = 3; btnTargets.Layout.Column = [1 2];

    btnSensors = uibutton(gl,'Text','Окно 3: Датчики / электроды', ...
        'ButtonPushedFcn',@(s,e)open_sensors_editor());
    btnSensors.Layout.Row = 4; btnSensors.Layout.Column = [1 2];

    btnAdvanced = uibutton(gl,'Text','Окно 4: Дополнительные параметры', ...
        'ButtonPushedFcn',@(s,e)open_advanced_editor());
    btnAdvanced.Layout.Row = 5; btnAdvanced.Layout.Column = [1 2];

    btnMUController = uibutton(gl,'Text','Окно 5: Контроллер ДЕ (Fuglevand)', ...
        'ButtonPushedFcn',@(s,e)open_mu_controller_editor(),'BackgroundColor',[0.95 0.85 0.6]);
    btnMUController.Layout.Row = 6; btnMUController.Layout.Column = [1 2];

    btnSmoke = uibutton(gl,'Text','Запустить симуляцию', ...
        'ButtonPushedFcn',@(s,e)on_run_simulation(),'BackgroundColor',[0.3 0.7 0.3]);
    btnSmoke.Layout.Row = 7; btnSmoke.Layout.Column = 1;
    
    btnVisualize = uibutton(gl,'Text','Визуализация результатов', ...
        'ButtonPushedFcn',@(s,e)on_visualize(),'BackgroundColor',[0.3 0.5 0.8]);
    btnVisualize.Layout.Row = 7; btnVisualize.Layout.Column = 2;

    btnLoad = uibutton(gl,'Text','Загрузить cfg (*.mat)', ...
        'ButtonPushedFcn',@(s,e)on_load_cfg());
    btnLoad.Layout.Row = 8; btnLoad.Layout.Column = 1;

    btnSave = uibutton(gl,'Text','Сохранить cfg (*.mat)', ...
        'ButtonPushedFcn',@(s,e)on_save_cfg());
    btnSave.Layout.Row = 8; btnSave.Layout.Column = 2;

    txt = uitextarea(gl,'Editable','off');
    txt.Layout.Row = 9; txt.Layout.Column = [1 2];
    txt.Value = {'Готово. Откройте окна редакторов, затем сохраните cfg.'};

    btnClose = uibutton(gl,'Text','Закрыть и вернуть cfg', ...
        'ButtonPushedFcn',@(s,e)uiresume(hub));
    btnClose.Layout.Row = 10; btnClose.Layout.Column = [1 2];


    % keep state
    setappdata(hub,'cfg',cfg);
    setappdata(hub,'txt',txt);

    % if called with "save" intent
    if nargin >= 2 && ischar(varargin{1}) && strcmpi(varargin{1},'save')
        setappdata(hub,'autosave_path', varargin{2});
    end

    uiwait(hub);

    % return cfg to caller
    if isvalid(hub)
        cfg = getappdata(hub,'cfg');
        autosave_path = [];
        if isappdata(hub,'autosave_path'), autosave_path = getappdata(hub,'autosave_path'); end
        delete(hub);
        if ~isempty(autosave_path)
            save(autosave_path,'cfg');
        end
    end

    % ---------------- nested callbacks ----------------

    function logline(s)
        if ~isvalid(hub), return; end
        txt = getappdata(hub,'txt');
        v = txt.Value;
        if ischar(v), v = {v}; end
        v{end+1} = s;
        if numel(v) > 200, v = v(end-199:end); end
        txt.Value = v; % cellstr
        drawnow limitrate;
    end

    function set_cfg(newcfg)
        newcfg = validate_cfg_for_core(newcfg);
        setappdata(hub,'cfg',newcfg);
    end

    function c = get_cfg()
        c = getappdata(hub,'cfg');
    end

    function on_validate_cfg()
        try
            c = validate_cfg_for_core(get_cfg());
            set_cfg(c);
            s = cfg_summary(c);
            logline(sprintf('OK: cfg валиден для ядра. %s', s));
        catch ME
            uialert(hub, ME.message, 'cfg validation error');
        end
    end

    function on_run_simulation()
        try
            c = validate_cfg_for_core(get_cfg());
            set_cfg(c);
            if exist('emg_simulation_core','file') ~= 2
                uialert(hub,'Функция emg_simulation_core не найдена в MATLAB path. Добавьте файл ядра в path.','No core');
                return;
            end
            logline('Запуск симуляции с текущей конфигурацией...');
            drawnow;
            results = emg_simulation_core(c);
            logline(sprintf('Симуляция завершена! Время: %.2f с', sum(struct2array(results.computation_time))));
            
            % Сохранить результаты в base workspace
            assignin('base','emg_results',results);
            logline('Результаты сохранены в переменную emg_results');
        catch ME
            uialert(hub, ME.message, 'Simulation failed');
            logline(sprintf('ОШИБКА: %s', ME.message));
        end
    end

    function on_visualize()
        try
            data_path = './emg_simulation_data';
            if exist('emg_visualize_saved','file') ~= 2
                uialert(hub,'Функция emg_visualize_saved не найдена. Добавьте файл в MATLAB path.','Визуализация');
                return;
            end
            
            % Проверяем существование папки с данными
            if ~exist(data_path, 'dir')
                % Пробуем найти данные в текущей директории
                logline('Папка ./emg_simulation_data не найдена, ищем альтернативы...');
                if exist('./emg_data', 'dir')
                    data_path = './emg_data';
                else
                    [folder] = uigetdir('.', 'Выберите папку с данными симуляции');
                    if folder == 0
                        return;
                    end
                    data_path = folder;
                end
            end
            
            logline(sprintf('Запуск визуализации из %s...', data_path));
            emg_visualize_saved(data_path);
            logline('Визуализация запущена.');
        catch ME
            uialert(hub, ME.message, 'Visualization failed');
            logline(sprintf('ОШИБКА визуализации: %s', ME.message));
        end
    end

    function on_load_cfg()
        [f,p] = uigetfile('*.mat','Load cfg');
        if isequal(f,0), return; end
        S = load(fullfile(p,f));
        if isfield(S,'cfg'), c = S.cfg;
        elseif isfield(S,'config'), c = S.config;
        else, error('Файл не содержит переменной cfg или config');
        end
        c = validate_cfg_for_core(c);
        set_cfg(c);
        logline(sprintf('Загружено: %s', fullfile(p,f)));
    end

    function on_save_cfg()
        c = validate_cfg_for_core(get_cfg());
        set_cfg(c);
        [f,p] = uiputfile('*.mat','Save cfg','cfg_emg.mat');
        if isequal(f,0), return; end
        cfg = c; 
        save(fullfile(p,f),'cfg','-v7.3');
        logline(['Сохранено: ', fullfile(p,f)]);
    end

    function open_geometry_editor()
        c = get_cfg();
        geometry_editor(c, @set_cfg);
        logline('Окно геометрии открыто.');
    end

    function open_targets_editor()
        c = get_cfg();
        targets_editor(c, @set_cfg);
        logline('Окно целевых сил открыто.');
    end

    function open_sensors_editor()
        c = get_cfg();
        sensors_editor(c, @set_cfg);
        logline('Окно датчиков открыто.');
    end

    function open_advanced_editor()
        c = get_cfg();
        advanced_editor(c, @set_cfg);
        logline('Окно дополнительных параметров открыто.');
    end

    function open_mu_controller_editor()
        c = get_cfg();
        mu_controller_editor(c, @set_cfg);
        logline('Окно контроллера ДЕ открыто.');
    end
end

%% =========================================================================
% DEFAULTS + VALIDATION
% =========================================================================
function cfg = cfg_default()
    cfg = struct();

    % --- simulation
    cfg.simulation = struct();
    cfg.simulation.duration   = 1.0;
    cfg.simulation.fs_internal = 10000;
    cfg.simulation.fs_output   = 2000;
    cfg.simulation.solver_mode = 'leadfield'; % 'leadfield'|'farina'|'fem'|'both'

    % --- geometry (cylinder parametric)
    cfg.geometry = struct();
    cfg.geometry.type = 'parametric';
    cfg.geometry.length = 0.25;
    cfg.geometry.radius_outer = 0.035;
    cfg.geometry.skin_thickness = 0.0015;
    cfg.geometry.fat_thickness  = 0.0040;
    cfg.geometry.fascia_thickness = 0.0005;

    % bones (simple default)
    cfg.geometry.bones = struct();
    cfg.geometry.bones.positions = [0.015, 0; -0.015, 0];  % [x y] in m
    cfg.geometry.bones.radii     = [0.004, 0.012];         % m

    % --- tissues conductivities (realistic values, S/m)
    cfg.tissues = struct();
    cfg.tissues.skin.sigma = 0.2;          % было 0.0002 - слишком мало!
    cfg.tissues.fat.sigma  = 0.04;
    cfg.tissues.muscle.sigma_long = 0.6;
    cfg.tissues.muscle.sigma_trans= 0.15;
    cfg.tissues.fascia.sigma= 0.1;
    cfg.tissues.bone.sigma  = 0.02;

    % --- motor units global (type-dependent parameters for size principle)
    cfg.motor_units = struct();
    cfg.motor_units.types = {'S','FR','FF'};
    cfg.motor_units.type_distribution = [0.5, 0.3, 0.2];
    cfg.motor_units.cv_range = [3.0, 4.5, 6.0];           % м/с по типам
    cfg.motor_units.n_fibers_range = [50, 150, 300];      % число волокон по типам
    cfg.motor_units.twitch_amplitude_range = [0.05, 0.3, 1.0];  % относительные веса
    cfg.motor_units.twitch_rise_time = [0.080, 0.050, 0.030];   % с
    cfg.motor_units.twitch_fall_time = [0.120, 0.070, 0.040];   % с
    cfg.motor_units.recruitment_threshold_range = [0.01, 0.60]; % согласовано с ядром
    
    % Типо-зависимые параметры firing rate (S, FR, FF)
    cfg.motor_units.firing_rate_min = [6, 8, 10];         % Гц по типам
    cfg.motor_units.firing_rate_max = [22, 32, 42];       % Гц по типам
    cfg.motor_units.firing_rate_gain = [25, 30, 35];      % прирост по типам
    cfg.motor_units.isi_cv = 0.15;                        % коэф. вариации ISI (gamma renewal)
    
    % Параметр нелинейности порога (k в формуле threshold = min + rank^k * range)
    cfg.motor_units.threshold_exponent = 2.0;             % 1.5-3.0 типично
    cfg.motor_units.refractory_s = 0.003;                 % Абсолютный рефрактерный период (с)

    % ПАТЧ 5: Onion skin principle (Fuglevand 1993, De Luca & Erim 1994)
    % При onion_skin = true: PFR убывает с порогом рекрутирования,
    % MFR единая для всех MU. Это даёт физиологически корректный паттерн:
    % рано рекрутированные MU стреляют быстрее поздних.
    cfg.motor_units.onion_skin = false;                     % true (Fuglevand) | false (типо-зависимые FR, legacy)
    cfg.motor_units.onion_skin_mfr = 8.0;                  % Единая минимальная FR для всех MU (Гц)
    cfg.motor_units.onion_skin_pfr_first = 35.0;            % PFR первой (наименьшей) MU (Гц)
    cfg.motor_units.onion_skin_pfrd = 20.0;                 % Диапазон уменьшения PFR (Гц)

    % ПАТЧ 10: Эллиптические территории MU (Petersen 2019)
    cfg.motor_units.territory_elliptical = false;           % true = эллиптические (для плоских мышц)
    cfg.motor_units.territory_aspect_ratio = 2.0;           % Отношение длинной к короткой оси (≥1)
    % territory_angle_deg: авто-определение из полигона мышцы, или задать вручную

    % --- common drive (ПАТЧ 1: общий нейронный сигнал для всех ДЕ)
    cfg.motor_units.common_drive = struct();
    cfg.motor_units.common_drive.enabled = true;
    cfg.motor_units.common_drive.strength = 0.15;          % Доля common drive (0..0.4)
    cfg.motor_units.common_drive.lpf_hz = 3.0;             % Полоса common drive (1..5 Гц)
    cfg.motor_units.common_drive.indep_strength = 0.10;    % Независимый шум (0..0.2)
    cfg.motor_units.common_drive.indep_lpf_hz = 15.0;      % Полоса индивидуального шума
    cfg.motor_units.common_drive.sync_prob = 0.02;         % Вероятность синхронизации
    cfg.motor_units.common_drive.seed = 42;                % Seed для воспроизводимости
    cfg.motor_units.common_drive.mode = 'multiplicative';   % ПАТЧ 6: 'additive' (Fuglevand) | 'multiplicative' (legacy)

    % --- spike model
    cfg.motor_units.spike_model = 'gamma_renewal';         % 'threshold' | 'gamma_renewal'

    % --- force dynamics (ПАТЧ 2: нелинейная активация + утомление)
    cfg.motor_units.force_dynamics = struct();
    cfg.motor_units.force_dynamics.enabled = true;
    cfg.motor_units.force_dynamics.tau_rise = [0.020, 0.015, 0.010];   % Время нарастания (S,FR,FF) с
    cfg.motor_units.force_dynamics.tau_decay = [0.120, 0.070, 0.040];  % Время спада (S,FR,FF) с
    cfg.motor_units.force_dynamics.hill_n = 3.0;           % Экспонента Hill (2..4)
    cfg.motor_units.force_dynamics.a50 = 0.35;             % Полумаксимальная активация (0.3..0.5)
    cfg.motor_units.force_dynamics.spike_gain = 'auto';    % 'auto' = авто-калибровка в ядре
    cfg.motor_units.force_dynamics.fatigue_enabled = false;
    cfg.motor_units.force_dynamics.fatigue_rate = 0.001;
    cfg.motor_units.force_dynamics.recovery_rate = 0.0005;
    cfg.motor_units.force_dynamics.fatigue_force_k = 0.3;
    cfg.motor_units.force_dynamics.fatigue_cv_k = 0.2;

    % --- sources
    cfg.sources = struct();
    cfg.sources.muap_window = 0.030;  % 30 мс для захвата хвостов и концевых эффектов
    
    % MUAP shape parameters (matching emg_simulation_core defaults)
    cfg.sources.muap = struct();
    cfg.sources.muap.ap_duration_ms = 3.0;       % Длительность IAP (мс), обычно 2-5 мс
    cfg.sources.muap.spatial_sigma_m = NaN;      % Пространственная ширина (м), NaN = авто
    cfg.sources.muap.tripole_spacing_m = NaN;    % Расстояние триполя (м), NaN = авто
    cfg.sources.muap.end_taper_m = 0.005;        % Зона затухания у концов (м) — legacy, см. use_legacy_taper
    cfg.sources.muap.dipole_moment_Am = 5e-10;   % Масштаб дипольного момента (А*м)
    % ПАТЧ 3: Модель экстинкции (непропагирующие компоненты на концах волокна)
    cfg.sources.muap.use_legacy_taper = false;    % true = старый taper, false = экстинкция
    cfg.sources.muap.extinction_tau_s = 0.5e-3;   % Постоянная времени экстинкции (с)
    cfg.sources.muap.extinction_sigma_m = 0.002;   % Пространственная ширина экстинкции (м)
    cfg.sources.muap.extinction_amplitude = 0.8;   % Амплитуда экстинкции (доля от пика ПД)

    % --- fiber biophysics (ПАТЧ 3+4: биофизическая модель источника IAP)
    cfg.fibers = struct();
    cfg.fibers.use_biophysical_source = true;  % Использовать биофизическую модель
    cfg.fibers.iap_model = 'rosenfalck';       % Модель IAP: 'rosenfalck', 'hh', 'fhn', 'gaussian'
    
    % Параметры мембраны
    cfg.fibers.Cm_uF_per_cm2 = 1.0;            % Ёмкость мембраны (мкФ/см²)
    cfg.fibers.Rm_Ohm_cm2 = 4000;              % Сопротивление мембраны (Ом·см²)
    cfg.fibers.Ri_Ohm_cm = 125;                % Внутриклеточное сопротивление (Ом·см)
    
    % Параметры потенциала действия
    cfg.fibers.Vm_rest_mV = -85;               % Потенциал покоя (мВ)
    cfg.fibers.Vm_peak_mV = 30;                % Пиковый потенциал (мВ)
    cfg.fibers.AP_duration_ms = 3.0;           % Длительность ПД (мс)
    
    % Диаметры волокон по типам MU [S, FR, FF] (мкм)
    cfg.fibers.diam_range_um = [35, 50, 65];
    
    % CV по типам MU [S, FR, FF] (м/с) - связано с диаметром
    cfg.fibers.cv_range = [3.0, 4.0, 5.0];
    
    % Внутри/внеклеточная проводимость (См/м)
    cfg.fibers.sigma_i = 1.0;
    cfg.fibers.sigma_e = 0.4;
    
    % Параметры модели Rosenfalck
    cfg.fibers.rosenfalck_A = 96;              % Коэффициент амплитуды (мВ/мм³)
    cfg.fibers.rosenfalck_lambda = 1.0;        % Постоянная длины (мм)
    
    % Температура (для HH модели)
    cfg.fibers.temperature = 37;               % Температура (°C)

    % --- solver (параметры решателя объёмного проводника)
    cfg.solver = struct();
    cfg.solver.leadfield_corrections = true;   % ПАТЧ 7: коррекция границ и анизотропии в leadfield
    cfg.solver.farina = struct();
    cfg.solver.farina.n_k_points = 64;         % Число точек интегрирования по k
    cfg.solver.farina.k_max = 1500;            % Максимальная пространственная частота (1/м)
    cfg.solver.farina.n_bessel_terms = 30;     % Число членов ряда Бесселя
    cfg.solver.farina.use_cache = true;        % Использовать кеширование

    % FEM параметры сетки (ПАТЧ FEM v3)
    cfg.fem = struct();
    cfg.fem.h_fine = 0.002;     % Шаг сетки у поверхности (м), 2мм (было 3мм)
    cfg.fem.h_coarse = 0.005;   % Шаг сетки в глубине (м), 5мм (было 6мм)
    cfg.fem.h_z = 0.003;        % Шаг вдоль оси z (м), 3мм (было 5мм — критично для z-дипольных источников)
    
    % --- muap_library (библиотека предрасчитанных MUAP)
    cfg.muap_library = struct();
    cfg.muap_library.enabled = false;          % Использовать библиотеку MUAP
    cfg.muap_library.cache_file = '';          % Путь к файлу кеша
    cfg.muap_library.auto_precompute = true;   % Автоматический предрасчёт
    cfg.muap_library.n_depth_points = 8;       % Число точек по глубине
    cfg.muap_library.n_cv_points = 8;          % Число точек по CV
    cfg.muap_library.n_fat_points = 4;         % Число точек по толщине жира
    cfg.muap_library.save_after_compute = true; % Сохранять после расчёта

    % --- saving
    cfg.save_data = true;
    cfg.save_path = './emg_simulation_data';
    cfg.save_incremental = false;
    cfg.save_interval = 1.0;

    % --- Сетевая помеха (mains interference) ---
    cfg.interference = struct();
    cfg.interference.mains = struct();
    cfg.interference.mains.enabled = false;
    cfg.interference.mains.frequency = 50;          % Гц (50 или 60)
    cfg.interference.mains.amplitude_Vp = 1e-3;     % Амплитуда синфазной помехи (В, пик)
    cfg.interference.mains.n_harmonics = 3;          % Число нечётных гармоник (1,3,5,7...)
    cfg.interference.mains.harmonic_decay = 0.3;     % Коэфф. затухания гармоник (относит.)
    cfg.interference.mains.dc_offset_V = 0;          % Постоянная составляющая (В)
    cfg.interference.mains.dc_offset_spread_V = 0.005; % Разброс DC между электродами (В)
    cfg.interference.mains.phase_noise_deg = 5;      % Фазовый шум между электродами (град)
    cfg.interference.mains.amplitude_noise = 0.05;   % Отн. вариация амплитуды между электродами

    % --- Объединение земель нескольких датчиков ---
    cfg.interference.ground_merge = struct();
    cfg.interference.ground_merge.enabled = false;
    cfg.interference.ground_merge.groups = {};        % cell-массив групп: {[1,2], [3,4]}

    % --- muscles (cell array, as in core)
    m = default_muscle('Flexor', 0);
    cfg.muscles = {m};

    % --- electrode arrays
    ea = default_electrode_array('Primary', 0);
    cfg.electrode_arrays = {ea};
end

function m = default_muscle(name, angle_deg)
    m = struct();
    m.name = name;
    m.position_angle = angle_deg;  % degrees on circumference
    m.depth = 0.018;               % radial distance from center (m)
    m.cross_section_area = 2.0e-4; % m^2 (2 cm^2)
    m.fiber_length = 0.12;         % m
    m.sigma = 26.8;                % N/cm^2
    m.n_motor_units = 120;
    m.fascia_thickness = 0.0003;   % m (per-muscle fascia layer)

    % shape: ellipse by default (polygon optional)
    m.polygon = []; % Nx2 local vertices (m) if used
    m.ellipse_aspect = 1.5;
    m.ellipse_angle = 0;

    % Распределение ДЕ в мышце
    m.mu_distribution = struct();
    m.mu_distribution.spatial = 'uniform';  % 'uniform', 'clustered', 'radial_gradient'
    m.mu_distribution.type_gradient = 'size_principle';  % 'random', 'size_principle', 'inverse'

    % target force profile - F_max вычисляется автоматически
    F_max_muscle = m.sigma * m.cross_section_area * 1e4;  % N
    fp = struct();
    fp.type = 'ramp_hold'; % 'ramp_hold'|'sine'|'trapezoid'|'constant'|'step'|'custom'
    fp.F_max = F_max_muscle * 0.3;  % 30% от максимальной силы мышцы в Ньютонах
    fp.F_max_percent = 30;           % процент для удобства
    fp.ramp_time = 0.25;
    fp.hold_time = 0.35;
    fp.ramp_down_time = 0.25;
    fp.step_time = 0.2;
    fp.pulse_duration = 0.1;
    fp.frequency = 0.5;
    fp.custom_data = [];   % [t, F] table
    m.force_profile = fp;
end

function ea = default_electrode_array(name, angle_deg)
    ea = struct();
    ea.name = name;
    ea.n_electrodes = 3;
    ea.shape = 'rect';
    ea.size = [0.005, 0.005]; % [w h] m
    ea.spacing = 0.010;       % along z in m
    ea.positions = [];        % optional [x_local z?] mapping in core: expects (x_local,y_local). Keep empty to use spacing
    ea.position_z = 0.12;     % center position along z in m
    ea.angle = angle_deg;     % degrees on cylinder

    ea.contact = struct('Rs', 200, 'Rc', 100e3, 'Cc', 100e-9);
    ea.differential_pairs = [1 3];
    ea.reference_electrode = 2;
    ea.spatial_filter = '';  % ПАТЧ 9: 'SD'|'DD'|'NDD'|'IR'|'' (пустая = legacy differential_pairs)

    ea.amplifier = struct();
    ea.amplifier.gain = 1000;
    ea.amplifier.cmrr_db = 90;
    ea.amplifier.noise_density = 5e-9;
    ea.amplifier.input_impedance = 200e6;  % 200 МОм (Z_cm_in INA)
    ea.amplifier.highpass_cutoff = 20;
    ea.amplifier.lowpass_cutoff = 450;
    ea.amplifier.notch_freq = 50;
    ea.amplifier.notch_bw = 2;

    % --- Позиционирование центрального (reference) электрода ---
    ea.ref_position = struct();
    ea.ref_position.custom_enabled = false;   % Использовать произвольную координату
    ea.ref_position.angle = angle_deg;        % Угол (град) - по умолчанию как массив
    ea.ref_position.position_z = 0.12;        % Z-координата (м)

    % --- Отдельный электрод земли ---
    ea.ground_electrode = struct();
    ea.ground_electrode.enabled = false;       % Использовать отдельный электрод земли
    ea.ground_electrode.angle = angle_deg + 90; % Угол земли (град)
    ea.ground_electrode.position_z = 0.06;     % Z-координата земли (м)
    ea.ground_electrode.Rc = 100e3;            % Сопротивление контакта земли (Ом)
    ea.ground_electrode.Cc = 100e-9;           % Ёмкость контакта земли (Ф)

    % --- Дисбаланс контакта электродов ---
    ea.contact_imbalance = struct();
    ea.contact_imbalance.enabled = false;
    ea.contact_imbalance.Rc_factors = [1.0, 1.0, 1.0]; % Множители Rc для [E1, E_ref, E3]
    ea.contact_imbalance.Cc_factors = [1.0, 1.0, 1.0]; % Множители Cc для [E1, E_ref, E3]
    ea.contact_imbalance.Rc_ground_factor = 1.0;        % Множитель Rc земли
    ea.contact_imbalance.Cc_ground_factor = 1.0;        % Множитель Cc земли
end

function cfg = validate_cfg_for_core(cfg)
    % Minimal and pragmatic validation for the current core.
    % This function also "patches" common issues.

    if ~isstruct(cfg), error('cfg must be a struct'); end
    if ~isfield(cfg,'simulation') || ~isstruct(cfg.simulation), error('cfg.simulation is required'); end

    % required numeric sanity
    mustpos(cfg.simulation,'duration',1e-3,inf);
    mustpos(cfg.simulation,'fs_internal',100,1e7);
    mustpos(cfg.simulation,'fs_output',10,1e7);

    if cfg.simulation.fs_output > cfg.simulation.fs_internal
        error('fs_output must be <= fs_internal');
    end
    ratio = cfg.simulation.fs_internal / cfg.simulation.fs_output;
    if abs(ratio - round(ratio)) > 1e-9
        % Core uses round() ratio; force exact integer ratio to avoid drift.
        cfg.simulation.fs_output = cfg.simulation.fs_internal / round(ratio);
    end

    if ~isfield(cfg,'geometry') || ~isstruct(cfg.geometry), error('cfg.geometry is required'); end
    mustpos(cfg.geometry,'length',0.01,5);
    mustpos(cfg.geometry,'radius_outer',0.005,0.2);
    mustpos(cfg.geometry,'skin_thickness',1e-4,0.02);
    mustpos(cfg.geometry,'fat_thickness',0,0.05);
    mustpos(cfg.geometry,'fascia_thickness',0,0.01);

    % muscles
    if ~isfield(cfg,'muscles') || isempty(cfg.muscles), error('cfg.muscles must be non-empty cell array'); end
    if ~iscell(cfg.muscles), error('cfg.muscles must be cell array of structs'); end
    for k=1:numel(cfg.muscles)
        m = cfg.muscles{k};
        req_fields = {'name','position_angle','depth','cross_section_area','fiber_length','sigma','n_motor_units','force_profile'};
        for r=1:numel(req_fields)
            if ~isfield(m,req_fields{r}), error('muscles{%d}.%s missing',k,req_fields{r}); end
        end
        if ~isfield(m,'polygon'), m.polygon = []; end
        if ~isfield(m,'fascia_thickness'), m.fascia_thickness = 0.0003; end

        % sanity
        if m.n_motor_units < 1 || m.n_motor_units > 5000
            error('muscles{%d}.n_motor_units out of expected range',k);
        end
        if m.cross_section_area <= 0, error('muscles{%d}.cross_section_area must be >0',k); end
        if m.fiber_length <= 0, error('muscles{%d}.fiber_length must be >0',k); end
        if m.sigma <= 0, error('muscles{%d}.sigma must be >0',k); end

        % force profile patching
        fp = m.force_profile;
        if ~isfield(fp,'type'), fp.type='ramp_hold'; end
        if ~isfield(fp,'F_max'), fp.F_max=0.3; end
        if ~isfield(fp,'custom_data'), fp.custom_data=[]; end
        if ~isfield(fp,'ramp_time'), fp.ramp_time=0.25; end
        if ~isfield(fp,'hold_time'), fp.hold_time=0.35; end
        if ~isfield(fp,'ramp_down_time'), fp.ramp_down_time=0.25; end
        if ~isfield(fp,'step_time'), fp.step_time=0.2; end
        if ~isfield(fp,'pulse_duration'), fp.pulse_duration=0.1; end
        if ~isfield(fp,'frequency'), fp.frequency=0.5; end
        m.force_profile = fp;

        cfg.muscles{k} = m;
    end

    % electrode arrays
    if ~isfield(cfg,'electrode_arrays') || isempty(cfg.electrode_arrays), error('cfg.electrode_arrays required'); end
    if ~iscell(cfg.electrode_arrays), error('cfg.electrode_arrays must be cell array'); end
    for ea=1:numel(cfg.electrode_arrays)
        a = cfg.electrode_arrays{ea};
        req = {'name','n_electrodes','shape','size','spacing','position_z','angle','contact','amplifier'};
        for r=1:numel(req)
            if ~isfield(a,req{r}), error('electrode_arrays{%d}.%s missing',ea,req{r}); end
        end
        if ~isfield(a,'positions'), a.positions = []; end
        if ~isfield(a,'differential_pairs'), a.differential_pairs = []; end
        if ~isfield(a,'reference_electrode'), a.reference_electrode = 0; end
        if a.n_electrodes < 1, error('electrode_arrays{%d}.n_electrodes must be >=1',ea); end
        
        % Patch: new electrode position/imbalance fields
        if ~isfield(a,'ref_position')
            a.ref_position = struct('custom_enabled',false,'angle',a.angle,'position_z',a.position_z);
        end
        if ~isfield(a,'ground_electrode')
            a.ground_electrode = struct('enabled',false,'angle',a.angle+90,...
                'position_z',0.06,'Rc',100e3,'Cc',100e-9);
        end
        if ~isfield(a,'contact_imbalance')
            a.contact_imbalance = struct('enabled',false,...
                'Rc_factors',[1 1 1],'Cc_factors',[1 1 1],...
                'Rc_ground_factor',1.0,'Cc_ground_factor',1.0);
        end
        
        cfg.electrode_arrays{ea} = a;
    end

    % Interference
    if ~isfield(cfg,'interference'), cfg.interference = struct(); end
    if ~isfield(cfg.interference,'mains')
        cfg.interference.mains = struct('enabled',false,'frequency',50,...
            'amplitude_Vp',1e-3,'n_harmonics',3,'harmonic_decay',0.3,...
            'dc_offset_V',0,'dc_offset_spread_V',0.005,...
            'phase_noise_deg',5,'amplitude_noise',0.05);
    end
    if ~isfield(cfg.interference,'ground_merge')
        cfg.interference.ground_merge = struct('enabled',false,'groups',{{}});
    end

    % motor_units / tissues / sources
    if ~isfield(cfg,'motor_units'), cfg.motor_units = cfg_default().motor_units; end
    if ~isfield(cfg,'tissues'), cfg.tissues = cfg_default().tissues; end
    if ~isfield(cfg,'sources'), cfg.sources = cfg_default().sources; end
    
    % Ensure common_drive, force_dynamics, spike_model exist in motor_units
    def_mu = cfg_default().motor_units;
    if ~isfield(cfg.motor_units, 'common_drive')
        cfg.motor_units.common_drive = def_mu.common_drive;
    end
    if ~isfield(cfg.motor_units, 'force_dynamics')
        cfg.motor_units.force_dynamics = def_mu.force_dynamics;
    end
    if ~isfield(cfg.motor_units, 'spike_model')
        cfg.motor_units.spike_model = def_mu.spike_model;
    end
    if ~isfield(cfg.motor_units, 'refractory_s')
        cfg.motor_units.refractory_s = def_mu.refractory_s;
    end
    
    % Ensure MUAP parameters exist
    if ~isfield(cfg.sources,'muap')
        cfg.sources.muap = cfg_default().sources.muap;
    else
        % Fill in missing MUAP fields with defaults
        def_muap = cfg_default().sources.muap;
        flds = fieldnames(def_muap);
        for i = 1:length(flds)
            if ~isfield(cfg.sources.muap, flds{i})
                cfg.sources.muap.(flds{i}) = def_muap.(flds{i});
            end
        end
    end
    
    % Ensure fiber biophysics parameters exist (ПАТЧ 3+4)
    if ~isfield(cfg, 'fibers')
        cfg.fibers = cfg_default().fibers;
    else
        % Fill in missing fiber fields with defaults
        def_fibers = cfg_default().fibers;
        flds = fieldnames(def_fibers);
        for i = 1:length(flds)
            if ~isfield(cfg.fibers, flds{i})
                cfg.fibers.(flds{i}) = def_fibers.(flds{i});
            end
        end
    end
    
    % Ensure Cm_F_per_m2 is consistent with Cm_uF_per_cm2
    if isfield(cfg.fibers, 'Cm_uF_per_cm2')
        cfg.fibers.Cm_F_per_m2 = cfg.fibers.Cm_uF_per_cm2 * 0.01;
    end

    if ~isfield(cfg,'save_data'), cfg.save_data=true; end
    if ~isfield(cfg,'save_path'), cfg.save_path='./emg_simulation_data'; end
end

function mustpos(S, field, lo, hi)
    if ~isfield(S,field), error('Missing field: %s',field); end
    v = S.(field);
    if ~isscalar(v) || ~isnumeric(v) || ~isfinite(v) || v < lo || v > hi
        error('Field %s out of range [%g..%g]',field,lo,hi);
    end
end

function s = cfg_summary(cfg)
    nm = numel(cfg.muscles);
    ne = numel(cfg.electrode_arrays);
    totMU = 0;
    for k=1:nm, totMU = totMU + cfg.muscles{k}.n_motor_units; end
    s = sprintf('muscles=%d, totalMU=%d, arrays=%d, mode=%s', nm, totMU, ne, cfg.simulation.solver_mode);
end

%% =========================================================================
% WINDOW 4: ADVANCED PARAMETERS + MU VISUALIZATION
% =========================================================================
function advanced_editor(cfg, set_cfg_cb)
    fig = uifigure('Name','Окно 4: Дополнительные параметры','Position',[110 80 1100 750],...
        'AutoResizeChildren','on','Resize','on');

    gl = uigridlayout(fig,[1 2]);
    gl.ColumnWidth = {500,'1x'};
    gl.Padding = [5 5 5 5];

    % Левая часть - tabs с параметрами
    tabs = uitabgroup(gl);
    tabs.Layout.Row = 1;
    tabs.Layout.Column = 1;

    
    % ===== Вкладка 1: Моторные единицы =====
    tab1 = uitab(tabs,'Title','Моторные единицы');
    pgl1 = uigridlayout(tab1,[17 2]);
    pgl1.ColumnWidth = {280,'1x'};
    pgl1.RowHeight = repmat({28},1,17);
    
    row = 1;
    lab1(pgl1,'Распределение типов [S, FR, FF]',row,1);
    edTypeDist = uieditfield(pgl1,'text','Value',mat2str(cfg.motor_units.type_distribution));
    place1(edTypeDist,row,2); row=row+1;
    
    lab1(pgl1,'Скорость проведения [S,FR,FF] (м/с)',row,1);
    edCV = uieditfield(pgl1,'text','Value',mat2str(cfg.motor_units.cv_range));
    place1(edCV,row,2); row=row+1;
    
    lab1(pgl1,'Число волокон [S, FR, FF]',row,1);
    n_fibers_val = getf(cfg.motor_units,'n_fibers_range',[50 150 300]);
    edNFibers = uieditfield(pgl1,'text','Value',mat2str(n_fibers_val));
    place1(edNFibers,row,2); row=row+1;
    
    lab1(pgl1,'Амплитуда твича [S, FR, FF]',row,1);
    edTwAmp = uieditfield(pgl1,'text','Value',mat2str(cfg.motor_units.twitch_amplitude_range));
    place1(edTwAmp,row,2); row=row+1;
    
    lab1(pgl1,'Время нарастания твича (с)',row,1);
    edTwRise = uieditfield(pgl1,'text','Value',mat2str(cfg.motor_units.twitch_rise_time));
    place1(edTwRise,row,2); row=row+1;
    
    lab1(pgl1,'Время спада твича (с)',row,1);
    edTwFall = uieditfield(pgl1,'text','Value',mat2str(cfg.motor_units.twitch_fall_time));
    place1(edTwFall,row,2); row=row+1;
    
    lab1(pgl1,'Диапазон порогов рекрутирования',row,1);
    edRecruit = uieditfield(pgl1,'text','Value',mat2str(cfg.motor_units.recruitment_threshold_range));
    place1(edRecruit,row,2); row=row+1;
    
    % Получаем значения firing rate (могут быть векторами или скалярами)
    fr_min_val = cfg.motor_units.firing_rate_min;
    fr_max_val = cfg.motor_units.firing_rate_max;
    fr_gain_val = cfg.motor_units.firing_rate_gain;
    if length(fr_min_val) > 1, fr_min_val = fr_min_val(1); end
    if length(fr_max_val) > 1, fr_max_val = fr_max_val(1); end
    if length(fr_gain_val) > 1, fr_gain_val = fr_gain_val(1); end
    
    lab1(pgl1,'Мин. частота разрядов (Гц, S)',row,1);
    edFRmin = uieditfield(pgl1,'numeric','Value',fr_min_val,'Limits',[1 50]);
    place1(edFRmin,row,2); row=row+1;
    
    lab1(pgl1,'Макс. частота разрядов (Гц, S)',row,1);
    edFRmax = uieditfield(pgl1,'numeric','Value',fr_max_val,'Limits',[10 100]);
    place1(edFRmax,row,2); row=row+1;
    
    lab1(pgl1,'Коэффициент усиления частоты (S)',row,1);
    edFRgain = uieditfield(pgl1,'numeric','Value',fr_gain_val,'Limits',[1 100]);
    place1(edFRgain,row,2); row=row+1;
    
    lab1(pgl1,'Экспонента порога (size principle)',row,1);
    thr_exp_val = getf(cfg.motor_units,'threshold_exponent',2.0);
    edThrExp = uieditfield(pgl1,'numeric','Value',thr_exp_val,'Limits',[1 5]);
    place1(edThrExp,row,2); row=row+1;
    
    lab1(pgl1,'Вариабельность МИИ (CV)',row,1);
    edISIcv = uieditfield(pgl1,'numeric','Value',cfg.motor_units.isi_cv,'Limits',[0 0.5]);
    place1(edISIcv,row,2); row=row+1;
    
    lab1(pgl1,'Масштаб территории ДЕ',row,1);
    edTerrScale = uieditfield(pgl1,'numeric','Value',getf(cfg.motor_units,'territory_scale',2.0),'Limits',[0.5 10]);
    place1(edTerrScale,row,2); row=row+1;
    
    lab1(pgl1,'Окно MUAP (с)',row,1);
    edMUAPwin = uieditfield(pgl1,'numeric','Value',cfg.sources.muap_window,'Limits',[0.005 0.1]);
    place1(edMUAPwin,row,2); row=row+1;

    % ===== Вкладка 2: Ткани =====
    tab2 = uitab(tabs,'Title','Ткани');
    pgl2 = uigridlayout(tab2,[8 2]);
    pgl2.ColumnWidth = {280,'1x'};
    pgl2.RowHeight = repmat({28},1,8);
    
    row = 1;
    lab1(pgl2,'Проводимость кожи (См/м)',row,1);
    edSkinSigma = uieditfield(pgl2,'numeric','Value',cfg.tissues.skin.sigma,'Limits',[1e-6 1]);
    place1(edSkinSigma,row,2); row=row+1;
    
    lab1(pgl2,'Проводимость жира (См/м)',row,1);
    edFatSigma = uieditfield(pgl2,'numeric','Value',cfg.tissues.fat.sigma,'Limits',[1e-4 1]);
    place1(edFatSigma,row,2); row=row+1;
    
    lab1(pgl2,'Проводимость мышцы продольная (См/м)',row,1);
    edMuscleSigmaL = uieditfield(pgl2,'numeric','Value',cfg.tissues.muscle.sigma_long,'Limits',[0.1 2]);
    place1(edMuscleSigmaL,row,2); row=row+1;
    
    lab1(pgl2,'Проводимость мышцы поперечная (См/м)',row,1);
    edMuscleSigmaT = uieditfield(pgl2,'numeric','Value',cfg.tissues.muscle.sigma_trans,'Limits',[0.01 1]);
    place1(edMuscleSigmaT,row,2); row=row+1;
    
    lab1(pgl2,'Проводимость фасции (См/м)',row,1);
    edFasciaSigma = uieditfield(pgl2,'numeric','Value',cfg.tissues.fascia.sigma,'Limits',[0.01 1]);
    place1(edFasciaSigma,row,2); row=row+1;
    
    lab1(pgl2,'Проводимость кости (См/м)',row,1);
    edBoneSigma = uieditfield(pgl2,'numeric','Value',cfg.tissues.bone.sigma,'Limits',[0.001 0.5]);
    place1(edBoneSigma,row,2); row=row+1;

    % ===== Вкладка 3: Симуляция =====
    tab3 = uitab(tabs,'Title','Симуляция');
    pgl3 = uigridlayout(tab3,[6 2]);
    pgl3.ColumnWidth = {280,'1x'};
    pgl3.RowHeight = repmat({28},1,6);
    
    row = 1;
    lab1(pgl3,'Внутренняя частота дискр. (Гц)',row,1);
    edFsInt = uieditfield(pgl3,'numeric','Value',cfg.simulation.fs_internal,'Limits',[1000 100000],'RoundFractionalValues','on');
    place1(edFsInt,row,2); row=row+1;
    
    lab1(pgl3,'Выходная частота дискр. (Гц)',row,1);
    edFsOut = uieditfield(pgl3,'numeric','Value',cfg.simulation.fs_output,'Limits',[100 20000],'RoundFractionalValues','on');
    place1(edFsOut,row,2); row=row+1;
    
    lab1(pgl3,'Сохранять данные',row,1);
    cbSave = uicheckbox(pgl3,'Value',cfg.save_data,'Text','');
    place1(cbSave,row,2); row=row+1;
    
    lab1(pgl3,'Путь сохранения',row,1);
    edSavePath = uieditfield(pgl3,'text','Value',cfg.save_path);
    place1(edSavePath,row,2); row=row+1;
    
    % ===== Вкладка 4: Источник MUAP (объединённая) =====
    tab4 = uitab(tabs,'Title','Источник MUAP');

    % Контейнер, который гарантирует корректное растяжение innerTabs
    glTab4 = uigridlayout(tab4,[1 1]);
    glTab4.RowHeight   = {'1x'};
    glTab4.ColumnWidth = {'1x'};
    glTab4.Padding     = [0 0 0 0];

    % Внутренние под-вкладки
    innerTabs = uitabgroup(glTab4);
    innerTabs.Layout.Row = 1;
    innerTabs.Layout.Column = 1;

    
    % --- Под-вкладка 4.1: Режим работы и общие настройки ---
    tabMode = uitab(innerTabs,'Title','Режим');
    pglMode = uigridlayout(tabMode,[14 2]);
    pglMode.ColumnWidth = {300,'1x'};
    pglMode.RowHeight = repmat({26},1,14);
    
    % Получаем параметры
    muap_cfg = getf(cfg.sources, 'muap', struct());
    fibers_cfg = getf(cfg, 'fibers', struct());
    muap_lib_cfg = getf(cfg, 'muap_library', struct());
    
    row = 1;
    % === Выбор режима генерации MUAP ===
    lblModeTitle = uilabel(pglMode,'Text','═══ РЕЖИМ ГЕНЕРАЦИИ MUAP ═══','FontWeight','bold','FontColor',[0.1 0.3 0.6]);
    lblModeTitle.Layout.Row = row; lblModeTitle.Layout.Column = [1 2]; row=row+1;
    
    % Информационная панель
    lblModeInfo = uilabel(pglMode,'Text',...
        ['Выберите способ расчёта формы потенциала:\n' ...
         '• Биофизический: точный расчёт Im(z) из модели IAP\n' ...
         '• Legacy триполь: упрощённый Гауссов триполь (+−+)\n' ...
         '• MUAP Library: интерполяция из предрасчитанной библиотеки'],...
        'VerticalAlignment','top');
    lblModeInfo.Layout.Row = [row row+2]; lblModeInfo.Layout.Column = [1 2]; row=row+3;
    
    lab1(pglMode,'Использовать биофизическую модель',row,1);
    cbUseBiophys = uicheckbox(pglMode,'Value',getf(fibers_cfg,'use_biophysical_source',true),'Text','');
    place1(cbUseBiophys,row,2); row=row+1;
    
    lab1(pglMode,'Использовать MUAP Library (кеш)',row,1);
    cbMUAPLibEnabled = uicheckbox(pglMode,'Value',getf(muap_lib_cfg,'enabled',false),'Text','');
    place1(cbMUAPLibEnabled,row,2); row=row+1;
    
    % Описание режимов
    row=row+1;
    lblModeDesc = uilabel(pglMode,'Text','','VerticalAlignment','top');
    lblModeDesc.Layout.Row = [row row+3]; lblModeDesc.Layout.Column = [1 2];
    
    % Callback для обновления описания режима
    function updateModeDescription()
        biophys = cbUseBiophys.Value;
        lib = cbMUAPLibEnabled.Value;
        
        if lib
            desc = ['РЕЖИМ: MUAP Library\n\n' ...
                    'Формы MUAP предрассчитываются один раз для сетки (глубина × CV × жир)\n' ...
                    'и затем интерполируются во время симуляции.\n\n' ...
                    '✓ Быстро (×100-500)\n' ...
                    '✓ Использует биофизическую модель IAP\n' ...
                    '⚠ Требует память (~10-50 МБ)'];
            lblModeDesc.FontColor = [0.0 0.5 0.0];
        elseif biophys
            desc = ['РЕЖИМ: Биофизический (real-time)\n\n' ...
                    'Мембранный ток Im(z) рассчитывается из профиля Vm(z)\n' ...
                    'по модели IAP (Rosenfalck, HH, FHN, Gaussian).\n\n' ...
                    '✓ Физически точный\n' ...
                    '✓ Гибкий (разные модели IAP)\n' ...
                    '⚠ Медленнее (~1-5 мс/источник)'];
            lblModeDesc.FontColor = [0.0 0.3 0.6];
        else
            desc = ['РЕЖИМ: Legacy триполь\n\n' ...
                    'Упрощённая модель: три Гауссовых источника (+−+)\n' ...
                    'с фиксированным дипольным моментом.\n\n' ...
                    '✓ Быстро\n' ...
                    '✓ Простая отладка\n' ...
                    '⚠ Менее физиологичен'];
            lblModeDesc.FontColor = [0.5 0.3 0.0];
        end
        lblModeDesc.Text = desc;
    end
    
    cbUseBiophys.ValueChangedFcn = @(s,e) updateModeDescription();
    cbMUAPLibEnabled.ValueChangedFcn = @(s,e) updateModeDescription();
    updateModeDescription();
    
    % --- Под-вкладка 4.2: Модель IAP (биофизика) ---
    tabIAP = uitab(innerTabs,'Title','Модель IAP');
    pglIAP = uigridlayout(tabIAP,[16 2]);
    pglIAP.ColumnWidth = {280,'1x'};
    pglIAP.RowHeight = repmat({26},1,16);
    
    row = 1;
    lblIAPTitle = uilabel(pglIAP,'Text','═══ МОДЕЛЬ ПОТЕНЦИАЛА ДЕЙСТВИЯ ═══','FontWeight','bold','FontColor',[0.1 0.3 0.6]);
    lblIAPTitle.Layout.Row = row; lblIAPTitle.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglIAP,'Модель IAP',row,1);
    ddIAPModel = uidropdown(pglIAP,'Items',{'rosenfalck','hh','fhn','gaussian'},...
        'Value',getf(fibers_cfg,'iap_model','rosenfalck'));
    place1(ddIAPModel,row,2); row=row+1;
    
    % Параметры потенциала действия
    lblAPTitle = uilabel(pglIAP,'Text','── Потенциал действия ──','FontWeight','bold');
    lblAPTitle.Layout.Row = row; lblAPTitle.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglIAP,'Потенциал покоя Vrest (мВ)',row,1);
    edFiberVrest = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'Vm_rest_mV',-85),'Limits',[-120 -50]);
    place1(edFiberVrest,row,2); row=row+1;
    
    lab1(pglIAP,'Пиковый потенциал Vpeak (мВ)',row,1);
    edFiberVpeak = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'Vm_peak_mV',30),'Limits',[-20 60]);
    place1(edFiberVpeak,row,2); row=row+1;
    
    lab1(pglIAP,'Длительность AP (мс)',row,1);
    edFiberAPdur = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'AP_duration_ms',3.0),'Limits',[0.5 10]);
    place1(edFiberAPdur,row,2); row=row+1;
    
    % Параметры мембраны
    lblMemTitle = uilabel(pglIAP,'Text','── Параметры мембраны ──','FontWeight','bold');
    lblMemTitle.Layout.Row = row; lblMemTitle.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglIAP,'Ёмкость мембраны Cm (мкФ/см²)',row,1);
    edFiberCm = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'Cm_uF_per_cm2',1.0),'Limits',[0.1 10]);
    place1(edFiberCm,row,2); row=row+1;
    
    lab1(pglIAP,'Сопротивление мембраны Rm (Ом·см²)',row,1);
    edFiberRm = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'Rm_Ohm_cm2',4000),'Limits',[500 20000]);
    place1(edFiberRm,row,2); row=row+1;
    
    lab1(pglIAP,'Внутриклеточное сопр. Ri (Ом·см)',row,1);
    edFiberRi = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'Ri_Ohm_cm',125),'Limits',[50 500]);
    place1(edFiberRi,row,2); row=row+1;
    
    % Диаметры и CV
    lblDiamTitle = uilabel(pglIAP,'Text','── Волокна по типам [S, FR, FF] ──','FontWeight','bold');
    lblDiamTitle.Layout.Row = row; lblDiamTitle.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglIAP,'Диаметры волокон (мкм)',row,1);
    edFiberDiam = uieditfield(pglIAP,'text','Value',mat2str(getf(fibers_cfg,'diam_range_um',[35,50,65])));
    place1(edFiberDiam,row,2); row=row+1;
    
    lab1(pglIAP,'Скорости проведения CV (м/с)',row,1);
    edFiberCV = uieditfield(pglIAP,'text','Value',mat2str(getf(fibers_cfg,'cv_range',[3.0,4.0,5.0])));
    place1(edFiberCV,row,2); row=row+1;
    
    % Проводимости
    lblCondTitle = uilabel(pglIAP,'Text','── Проводимости ──','FontWeight','bold');
    lblCondTitle.Layout.Row = row; lblCondTitle.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglIAP,'Внутриклеточная σi (См/м)',row,1);
    edFiberSigmaI = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'sigma_i',1.0),'Limits',[0.1 5]);
    place1(edFiberSigmaI,row,2); row=row+1;
    
    lab1(pglIAP,'Внеклеточная σe (См/м)',row,1);
    edFiberSigmaE = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'sigma_e',0.4),'Limits',[0.05 2]);
    place1(edFiberSigmaE,row,2); row=row+1;
    
    lab1(pglIAP,'Температура (°C, для HH)',row,1);
    edFiberTemp = uieditfield(pglIAP,'numeric','Value',getf(fibers_cfg,'temperature',37),'Limits',[20 45]);
    place1(edFiberTemp,row,2);
    
    % --- Под-вкладка 4.3: Legacy триполь ---
    tabLegacy = uitab(innerTabs,'Title','Legacy триполь');
    pglLegacy = uigridlayout(tabLegacy,[12 2]);
    pglLegacy.ColumnWidth = {280,'1x'};
    pglLegacy.RowHeight = repmat({26},1,12);
    
    row = 1;
    lblLegacyTitle = uilabel(pglLegacy,'Text','═══ ПАРАМЕТРЫ LEGACY ТРИПОЛЯ ═══','FontWeight','bold','FontColor',[0.5 0.3 0.0]);
    lblLegacyTitle.Layout.Row = row; lblLegacyTitle.Layout.Column = [1 2]; row=row+1;
    
    lblLegacyInfo = uilabel(pglLegacy,'Text',...
        ['Эти параметры используются ТОЛЬКО если биофизическая\n' ...
         'модель отключена. Триполь имеет форму (+−+) с\n' ...
         'Гауссовыми источниками.'],...
        'VerticalAlignment','top','FontColor',[0.4 0.4 0.4]);
    lblLegacyInfo.Layout.Row = [row row+1]; lblLegacyInfo.Layout.Column = [1 2]; row=row+2;
    
    lab1(pglLegacy,'Длительность IAP (мс)',row,1);
    edAPdur = uieditfield(pglLegacy,'numeric','Value',getf(muap_cfg,'ap_duration_ms',3.0),'Limits',[0.5 10]);
    place1(edAPdur,row,2); row=row+1;
    
    lab1(pglLegacy,'Пространственная σ (мм), 0=авто',row,1);
    spatial_sigma_val = getf(muap_cfg,'spatial_sigma_m',NaN);
    if isnan(spatial_sigma_val), spatial_sigma_val = 0; end
    edSpatialSigma = uieditfield(pglLegacy,'numeric','Value',spatial_sigma_val*1000,'Limits',[0 20]);
    place1(edSpatialSigma,row,2); row=row+1;
    
    lab1(pglLegacy,'Расстояние триполя (мм), 0=авто',row,1);
    tripole_val = getf(muap_cfg,'tripole_spacing_m',NaN);
    if isnan(tripole_val), tripole_val = 0; end
    edTripoleSpacing = uieditfield(pglLegacy,'numeric','Value',tripole_val*1000,'Limits',[0 30]);
    place1(edTripoleSpacing,row,2); row=row+1;
    
    lab1(pglLegacy,'Зона затухания у концов (мм)',row,1);
    edEndTaper = uieditfield(pglLegacy,'numeric','Value',getf(muap_cfg,'end_taper_m',0.010)*1000,'Limits',[0 50]);
    place1(edEndTaper,row,2); row=row+1;
    
    lab1(pglLegacy,'Дипольный момент (×10⁻¹⁰ А·м)',row,1);
    edDipoleMoment = uieditfield(pglLegacy,'numeric','Value',getf(muap_cfg,'dipole_moment_Am',5e-10)*1e10,'Limits',[0.1 100]);
    place1(edDipoleMoment,row,2); row=row+1;
    
    % Описание параметров
    row=row+1;
    lblLegacyDesc = uilabel(pglLegacy,'Text',...
        ['Влияние параметров:\n' ...
         '• IAP длительность → ширина волны в пространстве\n' ...
         '• σ пространственная → размытие источника\n' ...
         '• Триполь spacing → расстояние между фазами\n' ...
         '• Затухание → гашение волны на концах волокна\n' ...
         '• Дипольный момент → амплитуда сигнала'],...
        'VerticalAlignment','top');
    lblLegacyDesc.Layout.Row = [row row+3]; lblLegacyDesc.Layout.Column = [1 2];
    
    % --- Под-вкладка 4.4: MUAP Library ---
    tabLib = uitab(innerTabs,'Title','MUAP Library');
    pglLib = uigridlayout(tabLib,[14 2]);
    pglLib.ColumnWidth = {280,'1x'};
    pglLib.RowHeight = repmat({26},1,14);
    
    row = 1;
    lblLibTitle = uilabel(pglLib,'Text','═══ БИБЛИОТЕКА ПРЕДРАСЧИТАННЫХ MUAP ═══','FontWeight','bold','FontColor',[0.0 0.5 0.0]);
    lblLibTitle.Layout.Row = row; lblLibTitle.Layout.Column = [1 2]; row=row+1;
    
    lblLibInfo = uilabel(pglLib,'Text',...
        ['Библиотека предрассчитывает MUAP для сетки параметров\n' ...
         '(глубина × скорость проведения × толщина жира) и затем\n' ...
         'использует 4D интерполяцию во время симуляции.\n\n' ...
         'Ускорение: ×100-500 по сравнению с real-time расчётом.'],...
        'VerticalAlignment','top');
    lblLibInfo.Layout.Row = [row row+2]; lblLibInfo.Layout.Column = [1 2]; row=row+3;
    
    lblLibGrid = uilabel(pglLib,'Text','── Размер сетки ──','FontWeight','bold');
    lblLibGrid.Layout.Row = row; lblLibGrid.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglLib,'Точек по глубине',row,1);
    edMUAPDepthPts = uieditfield(pglLib,'numeric','Value',getf(muap_lib_cfg,'n_depth_points',8),'Limits',[4 32]);
    place1(edMUAPDepthPts,row,2); row=row+1;
    
    lab1(pglLib,'Точек по CV',row,1);
    edMUAPCVPts = uieditfield(pglLib,'numeric','Value',getf(muap_lib_cfg,'n_cv_points',8),'Limits',[4 32]);
    place1(edMUAPCVPts,row,2); row=row+1;
    
    lab1(pglLib,'Точек по толщине жира',row,1);
    edMUAPFatPts = uieditfield(pglLib,'numeric','Value',getf(muap_lib_cfg,'n_fat_points',4),'Limits',[2 16]);
    place1(edMUAPFatPts,row,2); row=row+1;
    
    lblLibOpt = uilabel(pglLib,'Text','── Опции ──','FontWeight','bold');
    lblLibOpt.Layout.Row = row; lblLibOpt.Layout.Column = [1 2]; row=row+1;
    
    lab1(pglLib,'Автопредрасчёт при запуске',row,1);
    cbMUAPAutoPrecompute = uicheckbox(pglLib,'Value',getf(muap_lib_cfg,'auto_precompute',true),'Text','');
    place1(cbMUAPAutoPrecompute,row,2); row=row+1;
    
    lab1(pglLib,'Сохранять кеш после расчёта',row,1);
    cbMUAPSaveAfter = uicheckbox(pglLib,'Value',getf(muap_lib_cfg,'save_after_compute',true),'Text','');
    place1(cbMUAPSaveAfter,row,2); row=row+1;
    
    % Оценка размера
    row=row+1;
    lblLibSize = uilabel(pglLib,'Text','','FontColor',[0.3 0.3 0.3]);
    lblLibSize.Layout.Row = row; lblLibSize.Layout.Column = [1 2];
    
    function updateLibrarySize()
        nd = edMUAPDepthPts.Value;
        ncv = edMUAPCVPts.Value;
        nf = edMUAPFatPts.Value;
        nt = 400;  % ~20ms @ 20kHz
        size_mb = nd * ncv * nf * nt * 8 / 1e6;  % double = 8 bytes
        lblLibSize.Text = sprintf('Оценка размера библиотеки: %.1f МБ (%d×%d×%d×%d)', size_mb, nd, ncv, nf, nt);
    end
    edMUAPDepthPts.ValueChangedFcn = @(s,e) updateLibrarySize();
    edMUAPCVPts.ValueChangedFcn = @(s,e) updateLibrarySize();
    edMUAPFatPts.ValueChangedFcn = @(s,e) updateLibrarySize();
    updateLibrarySize();
    
    % === Callbacks для обновления графика IAP ===
    ddIAPModel.ValueChangedFcn = @(s,e) refresh_iap_plot();
    edFiberCm.ValueChangedFcn = @(s,e) refresh_iap_plot();
    edFiberVrest.ValueChangedFcn = @(s,e) refresh_iap_plot();
    edFiberVpeak.ValueChangedFcn = @(s,e) refresh_iap_plot();
    edFiberAPdur.ValueChangedFcn = @(s,e) refresh_iap_plot();
    edFiberDiam.ValueChangedFcn = @(s,e) refresh_iap_plot();
    edFiberCV.ValueChangedFcn = @(s,e) refresh_iap_plot();

    % ===== Правая часть - визуализация =====
    pnlVis = uipanel(gl,'Title','Визуализация MUAP');
    pnlVis.Layout.Row = 1;
    pnlVis.Layout.Column = 2;

    visGL = uigridlayout(pnlVis,[6 1]);
    % 1) индикатор режима
    % 2) (axMU | axIAP) в одной строке
    % 3) MUAP на электроде
    % 4) Информация о MUAP (увеличиваем высоту)
    % 5) Контролы
    visGL.RowHeight = {50, '1x', '1x', 110, 40};
    
    % === Индикатор текущего режима ===
    pnlModeIndicator = uipanel(visGL,'Title','');
    pnlModeIndicator.Layout.Row = 1;
    modeGL = uigridlayout(pnlModeIndicator,[1 4]);
    modeGL.ColumnWidth = {120, '1x', 100, 100};
    modeGL.Padding = [5 2 5 2];
    
    lblCurrentMode = uilabel(modeGL,'Text','РЕЖИМ:','FontWeight','bold');
    lblModeValue = uilabel(modeGL,'Text','Биофизический','FontWeight','bold','FontColor',[0.0 0.3 0.6],'FontSize',12);
    
    % Параметры для preview
    uilabel(modeGL,'Text','Глубина (мм):');
    edPreviewDepth = uieditfield(modeGL,'numeric','Value',15,'Limits',[5 50],'ValueChangedFcn',@(s,e)refresh_muap_plot());
    
    % === Строка 2: два графика рядом (Сечение ДЕ + IAP профиль) ===
    row2GL = uigridlayout(visGL,[1 2]);
    row2GL.Layout.Row = 2;
    row2GL.ColumnWidth = {'1x','1x'};
    row2GL.RowHeight = {'1x'};
    row2GL.Padding = [0 0 0 0];
    row2GL.ColumnSpacing = 10;

    % === График сечения с ДЕ ===
    axMU = uiaxes(row2GL);
    title(axMU,'Сечение с моторными единицами');
    xlabel(axMU,'X (м)'); ylabel(axMU,'Y (м)');
    axMU.DataAspectRatio = [1 1 1];

    % === График IAP профиля (Vm и Im) ===
    axIAP = uiaxes(row2GL);
    title(axIAP,'Профиль потенциала действия (IAP)');
    xlabel(axIAP,'Позиция z (мм)');
    ylabel(axIAP,'Vm (мВ) / Im (отн. ед.)');
    axIAP.XGrid = 'on'; axIAP.YGrid = 'on';

    
    % === График MUAP на электроде ===
    axMUAP = uiaxes(visGL);
    axMUAP.Layout.Row = 3;
    title(axMUAP,'Форма MUAP на электроде');
    xlabel(axMUAP,'Время (мс)');
    ylabel(axMUAP,'Амплитуда (мкВ)');
    axMUAP.XGrid = 'on'; axMUAP.YGrid = 'on';
    
    % === Информационная панель ===
    pnlInfo = uipanel(visGL,'Title','Информация о MUAP');
    pnlInfo.Layout.Row = 4;
    infoGL = uigridlayout(pnlInfo,[2 4]);
    infoGL.ColumnWidth = {'1x','1x','1x','1x'};
    infoGL.RowHeight = {20, 20};
    infoGL.Padding = [5 2 5 2];
    
    lblInfoAmp = uilabel(infoGL,'Text','Амплитуда: -- мкВ');
    lblInfoDur = uilabel(infoGL,'Text','Длительность: -- мс');
    lblInfoPhases = uilabel(infoGL,'Text','Фазы: --');
    lblInfoCV = uilabel(infoGL,'Text','CV: -- м/с');
    
    lblInfoDepth = uilabel(infoGL,'Text','Глубина: -- мм');
    lblInfoSource = uilabel(infoGL,'Text','Источник: --');
    lblInfoLib = uilabel(infoGL,'Text','Library: --');
    lblInfoTime = uilabel(infoGL,'Text','Расчёт: -- мс');
    
    % === Контролы для визуализации ===
    ctrlGL = uigridlayout(visGL,[1 6]);
    ctrlGL.Layout.Row = 5;
    ctrlGL.ColumnWidth = {80,'1x',80,110,110,100};
    
    uilabel(ctrlGL,'Text','Мышца:');
    ddMuscle = uidropdown(ctrlGL,'Items',muscle_names(cfg),'ValueChangedFcn',@(s,e)refresh_all_plots());
    if ~isempty(cfg.muscles)
        ddMuscle.Value = cfg.muscles{1}.name;
    end
    
    btnRefresh = uibutton(ctrlGL,'Text','Обновить','ButtonPushedFcn',@(s,e)refresh_all_plots());
    btnValidate = uibutton(ctrlGL,'Text','Валидация MUAP','ButtonPushedFcn',@(s,e)run_muap_validation(),'BackgroundColor',[0.9 0.8 0.3]);
    btnCompare = uibutton(ctrlGL,'Text','Сравнить режимы','ButtonPushedFcn',@(s,e)compare_modes(),'BackgroundColor',[0.8 0.9 1.0]);
    btnApply = uibutton(ctrlGL,'Text','Применить','ButtonPushedFcn',@(s,e)on_close(),'BackgroundColor',[0.3 0.8 0.3]);
    
    % === Обновление индикатора режима ===
    function updateModeIndicator()
        biophys = cbUseBiophys.Value;
        lib = cbMUAPLibEnabled.Value;
        
        if lib
            lblModeValue.Text = 'MUAP Library (кеш)';
            lblModeValue.FontColor = [0.0 0.5 0.0];
            pnlModeIndicator.BackgroundColor = [0.9 1.0 0.9];
            lblInfoSource.Text = 'Источник: Library';
            lblInfoLib.Text = sprintf('Library: %dx%dx%d', edMUAPDepthPts.Value, edMUAPCVPts.Value, edMUAPFatPts.Value);
        elseif biophys
            lblModeValue.Text = sprintf('Биофизический (%s)', ddIAPModel.Value);
            lblModeValue.FontColor = [0.0 0.3 0.6];
            pnlModeIndicator.BackgroundColor = [0.9 0.95 1.0];
            lblInfoSource.Text = sprintf('Источник: %s', ddIAPModel.Value);
            lblInfoLib.Text = 'Library: выкл';
        else
            lblModeValue.Text = 'Legacy триполь';
            lblModeValue.FontColor = [0.5 0.3 0.0];
            pnlModeIndicator.BackgroundColor = [1.0 0.95 0.9];
            lblInfoSource.Text = 'Источник: Триполь';
            lblInfoLib.Text = 'Library: выкл';
        end
        
        % Обновляем описание в режиме
        updateModeDescription();
    end
    
    % Связываем callbacks
    cbUseBiophys.ValueChangedFcn = @(s,e) onModeChanged();
    cbMUAPLibEnabled.ValueChangedFcn = @(s,e) onModeChanged();
    ddIAPModel.ValueChangedFcn = @(s,e) onModeChanged();
    
    function onModeChanged()
        updateModeIndicator();
        updateModeDescription();
        refresh_iap_plot();
        refresh_muap_plot();
    end
    
    % Сохраняем cfg
    setappdata(fig,'cfg_local',cfg);
    
    % Первичная отрисовка
    updateModeIndicator();
    refresh_all_plots();

    % ===== Helper functions =====
    function lab1(parent, text, r, c)
        lbl = uilabel(parent,'Text',text);
        lbl.Layout.Row = r; lbl.Layout.Column = c;
    end
    function place1(comp, r, c)
        comp.Layout.Row = r; comp.Layout.Column = c;
    end
    
    function refresh_all_plots()
        refresh_mu_plot();
        refresh_iap_plot();
        refresh_muap_plot();
    end
    
    function refresh_iap_plot()
        % Визуализация профиля IAP (Vm и Im) на основе текущих параметров
        
        % Получаем параметры из полей ввода
        iap_model = ddIAPModel.Value;
        fiber_diam_um = str2num(edFiberDiam.Value);
        cv_range = str2num(edFiberCV.Value);
        Vm_rest = edFiberVrest.Value * 1e-3;  % мВ -> В
        Vm_peak = edFiberVpeak.Value * 1e-3;  % мВ -> В
        ap_dur_ms = edFiberAPdur.Value;
        Cm = edFiberCm.Value;
        Rm = edFiberRm.Value;
        Ri = edFiberRi.Value;
        
        % Используем средний диаметр и CV
        if ~isempty(fiber_diam_um)
            fiber_d = mean(fiber_diam_um);
        else
            fiber_d = 50;  % мкм
        end
        if ~isempty(cv_range)
            cv = mean(cv_range);
        else
            cv = 4.0;  % м/с
        end
        
        % ИСПРАВЛЕНИЕ: Полная очистка обеих осей Y при использовании yyaxis
        % Сначала переключаемся на левую ось и очищаем
        yyaxis(axIAP, 'left');
        cla(axIAP);
        % Затем переключаемся на правую ось и очищаем
        yyaxis(axIAP, 'right');
        cla(axIAP);
        % Возвращаемся к левой для начала отрисовки
        yyaxis(axIAP, 'left');
        
        % Пространственная координата (мм)
        z_mm = linspace(-10, 10, 200);
        z_m = z_mm * 1e-3;
        
        % Генерируем IAP профиль в зависимости от модели
        switch lower(iap_model)
            case 'rosenfalck'
                % Rosenfalck модель
                A = 96;  % мВ/мм³
                lambda_mm = 1.0;  % мм
                z_pos = max(z_mm, 0);  % Только положительная часть
                Vm_norm = A * (z_pos.^3) .* exp(-z_pos / lambda_mm);
                Vm_norm = Vm_norm / max(abs(Vm_norm) + eps);  % Нормировка
                
                % Im = d²Vm/dz² (вторая производная)
                dz = z_m(2) - z_m(1);
                d2Vm = [0, diff(Vm_norm, 2) / dz^2, 0];
                Im_norm = d2Vm / max(abs(d2Vm) + eps);
                
            case 'gaussian'
                % Гауссов триполь
                w = cv * ap_dur_ms * 1e-3 / 2;  % м
                w_mm = w * 1000;
                if w_mm < 0.1, w_mm = 0.1; end  % Защита от деления на 0
                Vm_norm = exp(-z_mm.^2 / (2 * w_mm^2));
                
                % Im как вторая производная Гаусса
                Im_norm = (z_mm.^2 / w_mm^4 - 1/w_mm^2) .* Vm_norm;
                Im_norm = Im_norm / max(abs(Im_norm) + eps);
                
            case 'hh'
                % Упрощённый HH-подобный профиль
                tau_ms = ap_dur_ms / 3;
                if tau_ms < 0.1, tau_ms = 0.1; end
                z_shifted = z_mm - 2;
                Vm_norm = (z_shifted > 0) .* z_shifted.^2 .* exp(-z_shifted / tau_ms);
                Vm_norm = Vm_norm / max(abs(Vm_norm) + eps);
                
                dz = z_m(2) - z_m(1);
                d2Vm = [0, diff(Vm_norm, 2) / dz^2, 0];
                Im_norm = d2Vm / max(abs(d2Vm) + eps);
                
            case 'fhn'
                % FitzHugh-Nagumo (упрощённый)
                w_mm = cv * ap_dur_ms * 1e-3 * 500;
                if w_mm < 0.1, w_mm = 0.1; end
                Vm_norm = tanh(z_mm / w_mm) .* (1 - tanh(z_mm / w_mm).^2);
                Vm_norm = Vm_norm / max(abs(Vm_norm) + eps);
                
                dz = z_m(2) - z_m(1);
                d2Vm = [0, diff(Vm_norm, 2) / dz^2, 0];
                Im_norm = d2Vm / max(abs(d2Vm) + eps);
                
            otherwise
                Vm_norm = zeros(size(z_mm));
                Im_norm = zeros(size(z_mm));
        end
        
        % Масштабируем Vm к реальным значениям
        Vm_mV = Vm_rest * 1000 + (Vm_peak - Vm_rest) * 1000 * Vm_norm;
        
        % Рисуем на левой оси (Vm)
        yyaxis(axIAP, 'left');
        plot(axIAP, z_mm, Vm_mV, 'b-', 'LineWidth', 1.5, 'DisplayName', 'Vm (мВ)');
        ylabel(axIAP, 'Vm (мВ)');
        axIAP.YColor = 'b';
        
        % Рисуем на правой оси (Im)
        yyaxis(axIAP, 'right');
        plot(axIAP, z_mm, Im_norm, 'r-', 'LineWidth', 1.5, 'DisplayName', 'Im (отн.)');
        ylabel(axIAP, 'Im (отн. ед.)');
        axIAP.YColor = 'r';
        
        xlabel(axIAP, 'Позиция z (мм)');
        title(axIAP, sprintf('IAP профиль: %s (d=%.0f мкм, CV=%.1f м/с)', iap_model, fiber_d, cv));
        legend(axIAP, 'Location', 'northeast');
        axIAP.XGrid = 'on';
        axIAP.YGrid = 'on';
    end
    
    function refresh_muap_plot()
        % refresh_muap_plot - Показывает форму MUAP на электроде (временную)
        % 
        % Учитывает текущий режим: биофизический, legacy или library preview
        
        tic;  % Замер времени
        
        % Получаем параметры
        cfg_loc = getappdata(fig,'cfg_local');
        depth_mm = edPreviewDepth.Value;
        depth_m = depth_mm * 1e-3;
        
        % CV из настроек
        cv_range = str2num(edFiberCV.Value);
        if isempty(cv_range), cv_range = 4.0; end
        cv = mean(cv_range);
        
        % Параметры IAP
        ap_dur_ms = edFiberAPdur.Value;
        Vm_rest = edFiberVrest.Value;
        Vm_peak = edFiberVpeak.Value;
        
        % Временная сетка
        fs = 10000;  % 10 кГц
        t = (0:1/fs:0.025)';  % 25 мс
        t_ms = t * 1000;
        
        % Определяем текущий режим
        use_biophys = cbUseBiophys.Value;
        use_library = cbMUAPLibEnabled.Value;
        iap_model = ddIAPModel.Value;
        
        % Генерируем форму MUAP
        if use_library
            % === РЕЖИМ LIBRARY: показываем что будет интерполировано ===
            % Для preview генерируем как биофизический
            [muap, source_name] = generate_muap_biophysical(t, depth_m, cv, ap_dur_ms, Vm_rest, Vm_peak, iap_model);
            source_name = sprintf('Library preview (%s)', iap_model);
        elseif use_biophys
            % === РЕЖИМ БИОФИЗИЧЕСКИЙ ===
            [muap, source_name] = generate_muap_biophysical(t, depth_m, cv, ap_dur_ms, Vm_rest, Vm_peak, iap_model);
        else
            % === РЕЖИМ LEGACY ТРИПОЛЬ ===
            [muap, source_name] = generate_muap_legacy(t, depth_m, cv, ap_dur_ms);
        end
        
        calc_time_ms = toc * 1000;
        
        % Конвертируем в мкВ
        muap_uV = muap * 1e6;
        
        % Вычисляем метрики
        amp_p2p = max(muap_uV) - min(muap_uV);
        
        % Длительность (10% от пика)
        threshold = 0.1 * max(abs(muap_uV));
        above = abs(muap_uV) > threshold;
        if any(above)
            first_idx = find(above, 1, 'first');
            last_idx = find(above, 1, 'last');
            duration_ms = (last_idx - first_idx) / fs * 1000;
        else
            duration_ms = 0;
        end
        
        % Число фаз
        zero_crossings = sum(diff(sign(muap)) ~= 0);
        n_phases = floor(zero_crossings / 2) + 1;
        
        % === Отрисовка ===
        cla(axMUAP);
        plot(axMUAP, t_ms, muap_uV, 'b-', 'LineWidth', 1.5);
        hold(axMUAP, 'on');
        
        % Отмечаем пик и минимум
        [peak_val, peak_idx] = max(muap_uV);
        [min_val, min_idx] = min(muap_uV);
        plot(axMUAP, t_ms(peak_idx), peak_val, 'r^', 'MarkerSize', 8, 'MarkerFaceColor', 'r');
        plot(axMUAP, t_ms(min_idx), min_val, 'rv', 'MarkerSize', 8, 'MarkerFaceColor', 'r');
        
        % Линия нуля
        yline(axMUAP, 0, 'k:', 'LineWidth', 0.5);
        
        hold(axMUAP, 'off');
        
        xlabel(axMUAP, 'Время (мс)');
        ylabel(axMUAP, 'Амплитуда (мкВ)');
        title(axMUAP, sprintf('MUAP на электроде (d=%.0f мм, CV=%.1f м/с) — %s', depth_mm, cv, source_name));
        axMUAP.XGrid = 'on';
        axMUAP.YGrid = 'on';
        xlim(axMUAP, [0 25]);
        
        % === Обновляем информационную панель ===
        lblInfoAmp.Text = sprintf('Амплитуда: %.1f мкВ', amp_p2p);
        lblInfoDur.Text = sprintf('Длительность: %.1f мс', duration_ms);
        lblInfoPhases.Text = sprintf('Фазы: %d', n_phases);
        lblInfoCV.Text = sprintf('CV: %.1f м/с', cv);
        lblInfoDepth.Text = sprintf('Глубина: %.0f мм', depth_mm);
        lblInfoTime.Text = sprintf('Расчёт: %.1f мс', calc_time_ms);
    end
    
    function [muap, source_name] = generate_muap_biophysical(t, depth, cv, ap_dur_ms, Vm_rest, Vm_peak, iap_model)
        % Генерирует MUAP используя биофизическую модель
        
        source_name = sprintf('Биофизика (%s)', iap_model);
        
        % Пытаемся использовать ActionPotentialModel
        if exist('ActionPotentialModel', 'class') == 8
            try
                model = ActionPotentialModel(iap_model);
                model.cv = cv;
                model.AP_duration_ms = ap_dur_ms;
                model.V_rest = Vm_rest * 1e-3;
                model.V_peak = Vm_peak * 1e-3;
                
                [~, Im, z_profile] = model.generate();
                
                % Конвертируем Im(z) в MUAP(t) через свёртку с функцией Грина
                % Упрощённая модель: MUAP ~ интеграл Im(z) * G(r,z)
                muap = convolve_im_to_muap(Im, z_profile, t, depth, cv);
                return;
            catch
                % Fallback к аналитической модели
            end
        end
        
        % Аналитическая модель (Rosenfalck-like)
        ap_dur_s = ap_dur_ms * 1e-3;
        spatial_length = cv * ap_dur_s;
        
        % Параметры формы
        t0 = 0.005;  % Задержка до пика
        sigma_t = ap_dur_s / 3;
        
        % Трёхфазная форма
        % Амплитуда зависит от глубины: A ~ 1/depth^1.5
        amp_base = 200e-6;  % Базовая амплитуда при depth=15mm
        amp = amp_base * (0.015 / depth)^1.5;
        
        t_shifted = t - t0;
        muap = -0.2*amp*exp(-(t_shifted - 0.001).^2/(2*sigma_t^2)) + ...
               amp*exp(-(t_shifted).^2/(2*sigma_t^2)) - ...
               0.3*amp*exp(-(t_shifted + 0.002).^2/(2*sigma_t^2));
    end
    
    function [muap, source_name] = generate_muap_legacy(t, depth, cv, ap_dur_ms)
        % Генерирует MUAP используя legacy триполь
        
        source_name = 'Legacy триполь';
        
        ap_dur_s = ap_dur_ms * 1e-3;
        w = max(0.001, 0.5 * cv * ap_dur_s);
        d_trip = 1.3 * w;
        
        % Амплитуда зависит от глубины
        amp_base = 200e-6;
        amp = amp_base * (0.015 / depth)^1.5;
        
        t0 = 0.005;
        sigma_t = w / cv;  % Временная ширина
        
        % Триполь во времени
        t_shifted = t - t0;
        muap = amp * (exp(-(t_shifted + d_trip/cv).^2/(2*sigma_t^2)) ...
                    - 2*exp(-(t_shifted).^2/(2*sigma_t^2)) ...
                    + exp(-(t_shifted - d_trip/cv).^2/(2*sigma_t^2)));
    end
    
    function muap = convolve_im_to_muap(Im, z_profile, t, depth, cv)
        % Конвертирует Im(z) в MUAP(t) через модель объёмного проводника
        
        % Упрощённая модель: MUAP(t) = sum_z Im(z) * G(depth, z_elec - z_source(t))
        % где z_source(t) = z_nmj + cv*t (распространяющийся фронт)
        
        muap = zeros(size(t));
        z_nmj = 0;
        sigma = 0.3;  % Проводимость
        
        for i = 1:length(t)
            % Позиция фронта в момент t
            z_front = z_nmj + cv * t(i);
            
            % Интегрируем вклад Im(z)
            for j = 1:length(z_profile)
                z_source = z_front + z_profile(j) - mean(z_profile);
                
                % Функция Грина для полупространства
                r = sqrt(depth^2 + z_source^2);
                if r > 1e-6
                    G = 1 / (4 * pi * sigma * r);
                    muap(i) = muap(i) + Im(j) * G * (z_profile(2) - z_profile(1));
                end
            end
        end
        
        % Дифференцируем (электрод измеряет градиент)
        muap = [0; diff(muap)] / (t(2) - t(1));
        
        % Нормализуем
        if max(abs(muap)) > 0
            muap = muap / max(abs(muap)) * 200e-6 * (0.015/depth)^1.5;
        end
    end
    
    function compare_modes()
        % compare_modes - Сравнивает MUAP для разных режимов
        
        depth_mm = edPreviewDepth.Value;
        depth_m = depth_mm * 1e-3;
        
        cv_range = str2num(edFiberCV.Value);
        if isempty(cv_range), cv_range = 4.0; end
        cv = mean(cv_range);
        
        ap_dur_ms = edFiberAPdur.Value;
        Vm_rest = edFiberVrest.Value;
        Vm_peak = edFiberVpeak.Value;
        iap_model = ddIAPModel.Value;
        
        fs = 10000;
        t = (0:1/fs:0.025)';
        t_ms = t * 1000;
        
        % Генерируем для всех режимов
        [muap_biophys, ~] = generate_muap_biophysical(t, depth_m, cv, ap_dur_ms, Vm_rest, Vm_peak, iap_model);
        [muap_legacy, ~] = generate_muap_legacy(t, depth_m, cv, ap_dur_ms);
        
        % Конвертируем в мкВ
        muap_biophys_uV = muap_biophys * 1e6;
        muap_legacy_uV = muap_legacy * 1e6;
        
        % Создаём окно сравнения
        fig_cmp = figure('Name', 'Сравнение режимов MUAP', 'Position', [200 200 900 600]);
        
        % Сравнение форм
        subplot(2,2,[1 2]);
        plot(t_ms, muap_biophys_uV, 'b-', 'LineWidth', 1.5, 'DisplayName', sprintf('Биофизический (%s)', iap_model));
        hold on;
        plot(t_ms, muap_legacy_uV, 'r--', 'LineWidth', 1.5, 'DisplayName', 'Legacy триполь');
        hold off;
        xlabel('Время (мс)');
        ylabel('Амплитуда (мкВ)');
        title(sprintf('Сравнение форм MUAP (d=%.0f мм, CV=%.1f м/с)', depth_mm, cv));
        legend('Location', 'northeast');
        grid on;
        
        % Метрики биофизического
        subplot(2,2,3);
        amp1 = max(muap_biophys_uV) - min(muap_biophys_uV);
        amp2 = max(muap_legacy_uV) - min(muap_legacy_uV);
        bar([amp1, amp2]);
        set(gca, 'XTickLabel', {'Биофизический', 'Legacy'});
        ylabel('Амплитуда (мкВ)');
        title('Сравнение амплитуд');
        grid on;
        
        % Корреляция
        subplot(2,2,4);
        corr_val = corrcoef(muap_biophys_uV, muap_legacy_uV);
        corr_val = corr_val(1,2);
        
        text(0.5, 0.6, sprintf('Корреляция: %.3f', corr_val), ...
            'HorizontalAlignment', 'center', 'FontSize', 14, 'FontWeight', 'bold');
        text(0.5, 0.4, sprintf('Разница амплитуд: %.1f%%', (amp1-amp2)/amp1*100), ...
            'HorizontalAlignment', 'center', 'FontSize', 12);
        axis off;
        title('Статистика');
        
        sgtitle(sprintf('Параметры: глубина %.0f мм, CV %.1f м/с, AP %.1f мс', depth_mm, cv, ap_dur_ms));
    end
    
    function w = soft_taper(dist_to_end, taper_m)
        if taper_m <= 0
            w = 1.0;
            return;
        end
        x = max(0.0, min(1.0, dist_to_end / taper_m));
        w = 0.5 - 0.5*cos(pi*x);
    end

    function refresh_mu_plot()
        cfg = getappdata(fig,'cfg_local');
        
        cla(axMU); hold(axMU,'on');
        axMU.DataAspectRatio = [1 1 1];
        
        Rskin = cfg.geometry.radius_outer;
        Rfat  = Rskin - cfg.geometry.skin_thickness;
        Rfas  = Rfat  - cfg.geometry.fat_thickness;
        Rmus  = Rfas  - cfg.geometry.fascia_thickness;
        
        % Рисуем слои тканей
        fill_circle_adv(axMU,0,0,Rskin,[0.9 0.9 0.9],0.15);   % skin
        fill_circle_adv(axMU,0,0,Rfat,[0.95 0.88 0.80],0.20);  % fat
        fill_circle_adv(axMU,0,0,Rfas,[0.85 0.92 0.85],0.15);  % fascia
        fill_circle_adv(axMU,0,0,Rmus,[0.85 0.88 0.95],0.12);  % muscle
        draw_circle_adv(axMU,0,0,Rskin,'k-',1.5);
        
        % Рисуем кости
        for b=1:size(cfg.geometry.bones.positions,1)
            x = cfg.geometry.bones.positions(b,1);
            y = cfg.geometry.bones.positions(b,2);
            r = cfg.geometry.bones.radii(b);
            fill_circle_adv(axMU,x,y,r,[0.95 0.95 0.90],0.8);
            draw_circle_adv(axMU,x,y,r,'k-',1);
        end
        
        % Рисуем все мышцы (контуры)
        for kk=1:numel(cfg.muscles)
            m = cfg.muscles{kk};
            [cx,cy] = muscle_center_xy(m);
            % Базовый центр мышцы
            ang_m = m.position_angle*pi/180;
            base_cx = m.depth*cos(ang_m);
            base_cy = m.depth*sin(ang_m);
            
            % Центроид для подписи
            [cx,cy] = muscle_center_xy(m);
            
            if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
                P = m.polygon + [base_cx, base_cy];
                plot(axMU,[P(:,1);P(1,1)],[P(:,2);P(1,2)],'Color',[0.4 0.4 0.6],'LineWidth',1);
            else
                [vx,vy] = muscle_ellipse_vertices(m);
                plot(axMU,vx,vy,'Color',[0.4 0.4 0.6],'LineWidth',1);
            end
            text(axMU,cx,cy,m.name,'FontSize',8,'HorizontalAlignment','center');
        end
        
        % Находим выбранную мышцу
        idx = find(strcmp(muscle_names(cfg), ddMuscle.Value), 1);
        if isempty(idx) && ~isempty(cfg.muscles), idx = 1; end
        
        if ~isempty(idx)
            m = cfg.muscles{idx};
            
            % Базовый центр мышцы
            ang_m = m.position_angle*pi/180;
            base_cx = m.depth*cos(ang_m);
            base_cy = m.depth*sin(ang_m);
            
            % Центроид
            [cx,cy] = muscle_center_xy(m);
            
            % Подсвечиваем выбранную мышцу
            if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
                P = m.polygon + [base_cx, base_cy];
                plot(axMU,[P(:,1);P(1,1)],[P(:,2);P(1,2)],'Color',[0.2 0.5 0.8],'LineWidth',2.5);
            else
                [vx,vy] = muscle_ellipse_vertices(m);
                plot(axMU,vx,vy,'Color',[0.2 0.5 0.8],'LineWidth',2.5);
            end
            
            % Генерируем предварительное распределение ДЕ
            n_mu = m.n_motor_units;
            n_show = min(n_mu, 100);  % Показываем до 100 ДЕ
            
            % Получаем параметры распределения
            spatial_dist = getf(getf(m,'mu_distribution',struct()),'spatial','uniform');
            type_gradient = getf(getf(m,'mu_distribution',struct()),'type_gradient','size_principle');
            
            % Проверяем, есть ли полигон
            has_polygon = isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3;
            
            % Получаем полуоси эллипса мышцы (используется если нет полигона)
            area = max(m.cross_section_area, 1e-8);
            aspect = getf(m,'ellipse_aspect',1.5);
            a = sqrt(area*aspect/pi);  % большая полуось
            b = sqrt(area/(pi*aspect)); % малая полуось
            rot_angle = getf(m,'ellipse_angle',0) * pi/180;
            
            % Генерируем координаты ДЕ
            mu_x = zeros(n_show,1);
            mu_y = zeros(n_show,1);
            mu_type = zeros(n_show,1);  % 1=S, 2=FR, 3=FF
            
            type_dist = cfg.motor_units.type_distribution;
            type_cumsum = cumsum(type_dist);
            
            % Если есть полигон, вычисляем его bounding box
            if has_polygon
                poly_pts = m.polygon + [base_cx, base_cy];  % Абсолютные координаты
                poly_min_x = min(poly_pts(:,1));
                poly_max_x = max(poly_pts(:,1));
                poly_min_y = min(poly_pts(:,2));
                poly_max_y = max(poly_pts(:,2));
            end
            
            for i=1:n_show
                % Определяем тип ДЕ
                norm_idx = (i-1)/(max(n_show-1,1));  % 0..1
                
                switch type_gradient
                    case 'size_principle'
                        % S ближе к центру, FF на периферии
                        if norm_idx < type_cumsum(1)
                            mu_type(i) = 1;
                        elseif norm_idx < type_cumsum(2)
                            mu_type(i) = 2;
                        else
                            mu_type(i) = 3;
                        end
                    case 'inverse'
                        % FF ближе к центру, S на периферии
                        if norm_idx < type_dist(3)
                            mu_type(i) = 3;
                        elseif norm_idx < type_dist(3) + type_dist(2)
                            mu_type(i) = 2;
                        else
                            mu_type(i) = 1;
                        end
                    otherwise % random
                        rr = rand();
                        if rr < type_cumsum(1), mu_type(i) = 1;
                        elseif rr < type_cumsum(2), mu_type(i) = 2;
                        else, mu_type(i) = 3; end
                end
                
                if has_polygon
                    % Генерируем позицию внутри полигона методом отбора
                    max_attempts = 100;
                    found = false;
                    for attempt = 1:max_attempts
                        % Случайная точка в bounding box
                        px = poly_min_x + rand() * (poly_max_x - poly_min_x);
                        py = poly_min_y + rand() * (poly_max_y - poly_min_y);
                        
                        % Проверяем, внутри ли полигона
                        if inpolygon(px, py, poly_pts(:,1), poly_pts(:,2))
                            % Применяем пространственное распределение
                            switch spatial_dist
                                case 'clustered'
                                    % Для кластеров смещаем к определённой части полигона
                                    cluster_angle = (mu_type(i)-1) * 2*pi/3;
                                    offset_x = (poly_max_x - poly_min_x) * 0.2 * cos(cluster_angle);
                                    offset_y = (poly_max_y - poly_min_y) * 0.2 * sin(cluster_angle);
                                    px = px + offset_x;
                                    py = py + offset_y;
                                    % Проверяем снова
                                    if ~inpolygon(px, py, poly_pts(:,1), poly_pts(:,2))
                                        continue;
                                    end
                                case 'radial_gradient'
                                    % Для радиального градиента - S ближе к центру
                                    dist_to_center = sqrt((px-cx)^2 + (py-cy)^2);
                                    max_dist = max(sqrt((poly_pts(:,1)-cx).^2 + (poly_pts(:,2)-cy).^2));
                                    target_dist = max_dist * (0.2 + 0.7 * (mu_type(i)-1)/2);
                                    if abs(dist_to_center - target_dist) > max_dist * 0.3
                                        continue;  % Попробуем ещё раз
                                    end
                            end
                            mu_x(i) = px;
                            mu_y(i) = py;
                            found = true;
                            break;
                        end
                    end
                    if ~found
                        % Fallback - центр полигона
                        mu_x(i) = cx;
                        mu_y(i) = cy;
                    end
                else
                    % Генерируем позицию внутри эллипса
                    switch spatial_dist
                        case 'clustered'
                            % Кластеры по типам
                            cluster_angle = (mu_type(i)-1) * 2*pi/3 + randn()*0.3;
                            cluster_r = 0.3 + 0.4*rand();
                            lx = cluster_r * a * cos(cluster_angle);
                            ly = cluster_r * b * sin(cluster_angle);
                        case 'radial_gradient'
                            % Радиальный градиент по типу
                            theta = rand() * 2*pi;
                            r_factor = 0.2 + 0.7 * (mu_type(i)-1)/2;  % S ближе к центру
                            r_factor = r_factor * (0.8 + 0.4*rand());
                            lx = r_factor * a * cos(theta);
                            ly = r_factor * b * sin(theta);
                        otherwise % uniform
                            % Равномерное распределение в эллипсе
                            theta = rand() * 2*pi;
                            r = sqrt(rand());  % sqrt для равномерности по площади
                            lx = r * a * cos(theta);
                            ly = r * b * sin(theta);
                    end
                    
                    % Поворот эллипса
                    mu_x(i) = cx + lx*cos(rot_angle) - ly*sin(rot_angle);
                    mu_y(i) = cy + lx*sin(rot_angle) + ly*cos(rot_angle);
                end
            end
            
            % Сохраняем позиции ДЕ в cfg для использования в симуляции
            cfg.muscles{idx}.mu_positions = [mu_x, mu_y];
            cfg.muscles{idx}.mu_types = mu_type;
            setappdata(fig,'cfg_local',cfg);
            
            % Рисуем ДЕ с цветовой кодировкой
            colors = [0.2 0.7 0.3;   % S - зелёный
                      0.2 0.4 0.8;   % FR - синий
                      0.8 0.2 0.2];  % FF - красный
            sizes = [40, 70, 100];   % размеры маркеров
            
            for t=1:3
                mask = mu_type == t;
                if any(mask)
                    scatter(axMU, mu_x(mask), mu_y(mask), sizes(t), colors(t,:), 'filled', 'MarkerFaceAlpha', 0.7);
                end
            end
            
            % Легенда
            h1 = scatter(axMU, nan, nan, sizes(1), colors(1,:), 'filled');
            h2 = scatter(axMU, nan, nan, sizes(2), colors(2,:), 'filled');
            h3 = scatter(axMU, nan, nan, sizes(3), colors(3,:), 'filled');
            legend(axMU, [h1 h2 h3], {'S (slow)', 'FR (fatigue-res)', 'FF (fast-fatig)'}, ...
                'Location', 'northeast', 'FontSize', 8);
            
            % Информация
            shape_str = 'эллипс';
            if has_polygon
                shape_str = sprintf('полигон %d т.', size(m.polygon,1));
            end
            title(axMU, sprintf('%s: %d ДЕ (%s, %s, %s)', m.name, n_mu, spatial_dist, type_gradient, shape_str));
        end
        
        axis(axMU, [-Rskin Rskin -Rskin Rskin]*1.15);
        hold(axMU,'off');
    end

    function run_muap_validation()
        % run_muap_validation - Запускает валидацию MUAP со справочными данными
        %
        % Использует текущий режим (биофизический/legacy) для генерации MUAP
        % и сравнивает с литературными референсами
        
        % Проверяем наличие класса MUAPValidator
        if exist('MUAPValidator', 'class') ~= 8
            errordlg('Класс MUAPValidator не найден. Убедитесь, что MUAPValidator.m в пути MATLAB.', 'Ошибка');
            return;
        end
        
        try
            % Получаем параметры из GUI
            iap_model = ddIAPModel.Value;
            cv_range = str2num(edFiberCV.Value);
            Vm_rest = edFiberVrest.Value;
            Vm_peak = edFiberVpeak.Value;
            ap_dur_ms = edFiberAPdur.Value;
            
            % Текущий режим
            use_biophys = cbUseBiophys.Value;
            
            if isempty(cv_range), cv_range = 4.0; end
            
            % Создаём валидатор
            validator = MUAPValidator();
            
            % Генерируем тестовые MUAP для разных параметров
            fs = 10000;
            t = (0:1/fs:0.025)';
            
            depths = [0.010, 0.015, 0.020, 0.025, 0.030];
            cvs = cv_range;
            if isscalar(cvs), cvs = [cvs*0.8, cvs, cvs*1.2]; end
            
            % Генерируем MUAP используя текущий режим
            for i = 1:length(depths)
                for j = 1:length(cvs)
                    depth = depths(i);
                    cv = cvs(j);
                    
                    if use_biophys
                        [muap, ~] = generate_muap_biophysical(t, depth, cv, ap_dur_ms, Vm_rest, Vm_peak, iap_model);
                    else
                        [muap, ~] = generate_muap_legacy(t, depth, cv, ap_dur_ms);
                    end
                    
                    params = struct('depth', depth, 'cv', cv, 'fiber_type', 'FR');
                    params.name = sprintf('d=%.0fmm_cv=%.1f', depth*1000, cv);
                    
                    validator.addMUAP(muap, fs, params);
                end
            end
            
            % Запускаем валидацию
            results = validator.validate();
            
            % Визуализация
            validator.visualize();
            
            % Определяем режим для сообщения
            if use_biophys
                mode_str = sprintf('Биофизический (%s)', iap_model);
            else
                mode_str = 'Legacy триполь';
            end
            
            % Информируем пользователя
            if results.failed == 0
                msgbox(sprintf('Валидация завершена!\n\nРежим: %s\nПройдено: %d\nПредупреждений: %d\nПровалено: %d', ...
                    mode_str, results.passed, results.warnings, results.failed), 'Результат валидации', 'help');
            else
                msgbox(sprintf('Валидация выявила проблемы.\n\nРежим: %s\nПройдено: %d\nПредупреждений: %d\nПровалено: %d', ...
                    mode_str, results.passed, results.warnings, results.failed), 'Результат валидации', 'warn');
            end
            
        catch e
            errordlg(sprintf('Ошибка валидации: %s', e.message), 'Ошибка');
        end
    end

    function on_close()
        cfg = getappdata(fig,'cfg_local');
        
        % Motor units
        try
            cfg.motor_units.type_distribution = eval(edTypeDist.Value);
            cfg.motor_units.cv_range = eval(edCV.Value);
            cfg.motor_units.n_fibers_range = eval(edNFibers.Value);
            cfg.motor_units.twitch_amplitude_range = eval(edTwAmp.Value);
            cfg.motor_units.twitch_rise_time = eval(edTwRise.Value);
            cfg.motor_units.twitch_fall_time = eval(edTwFall.Value);
            cfg.motor_units.recruitment_threshold_range = eval(edRecruit.Value);
        catch
            uialert(fig,'Ошибка в формате массивов. Используйте формат [a, b, c]','Error');
            return;
        end
        cfg.motor_units.firing_rate_min = edFRmin.Value;
        cfg.motor_units.firing_rate_max = edFRmax.Value;
        cfg.motor_units.firing_rate_gain = edFRgain.Value;
        
        % Преобразуем в типо-зависимые векторы [S, FR, FF]
        % FR и FF автоматически получают увеличенные значения
        if isscalar(cfg.motor_units.firing_rate_min)
            base_min = cfg.motor_units.firing_rate_min;
            cfg.motor_units.firing_rate_min = [base_min, base_min + 2, base_min + 4];
        end
        if isscalar(cfg.motor_units.firing_rate_max)
            base_max = cfg.motor_units.firing_rate_max;
            cfg.motor_units.firing_rate_max = [base_max, base_max + 10, base_max + 20];
        end
        if isscalar(cfg.motor_units.firing_rate_gain)
            base_gain = cfg.motor_units.firing_rate_gain;
            cfg.motor_units.firing_rate_gain = [base_gain, base_gain + 5, base_gain + 10];
        end
        
        cfg.motor_units.threshold_exponent = edThrExp.Value;
        cfg.motor_units.isi_cv = edISIcv.Value;
        cfg.motor_units.territory_scale = edTerrScale.Value;
        cfg.sources.muap_window = edMUAPwin.Value;
        
        % MUAP parameters
        if ~isfield(cfg.sources, 'muap')
            cfg.sources.muap = struct();
        end
        cfg.sources.muap.ap_duration_ms = edAPdur.Value;
        
        % Конвертируем из мм в м, 0 означает NaN (авто)
        spatial_val = edSpatialSigma.Value;
        if spatial_val == 0
            cfg.sources.muap.spatial_sigma_m = NaN;
        else
            cfg.sources.muap.spatial_sigma_m = spatial_val * 1e-3;
        end
        
        tripole_val = edTripoleSpacing.Value;
        if tripole_val == 0
            cfg.sources.muap.tripole_spacing_m = NaN;
        else
            cfg.sources.muap.tripole_spacing_m = tripole_val * 1e-3;
        end
        
        cfg.sources.muap.end_taper_m = edEndTaper.Value * 1e-3;
        cfg.sources.muap.dipole_moment_Am = edDipoleMoment.Value * 1e-10;
        
        % Tissues
        cfg.tissues.skin.sigma = edSkinSigma.Value;
        cfg.tissues.fat.sigma = edFatSigma.Value;
        cfg.tissues.muscle.sigma_long = edMuscleSigmaL.Value;
        cfg.tissues.muscle.sigma_trans = edMuscleSigmaT.Value;
        cfg.tissues.fascia.sigma = edFasciaSigma.Value;
        cfg.tissues.bone.sigma = edBoneSigma.Value;
        
        % Fiber biophysics (ПАТЧ 3+4)
        if ~isfield(cfg, 'fibers')
            cfg.fibers = struct();
        end
        cfg.fibers.use_biophysical_source = cbUseBiophys.Value;
        cfg.fibers.iap_model = ddIAPModel.Value;
        cfg.fibers.Cm_uF_per_cm2 = edFiberCm.Value;
        cfg.fibers.Rm_Ohm_cm2 = edFiberRm.Value;
        cfg.fibers.Ri_Ohm_cm = edFiberRi.Value;
        cfg.fibers.Vm_rest_mV = edFiberVrest.Value;
        cfg.fibers.Vm_peak_mV = edFiberVpeak.Value;
        cfg.fibers.AP_duration_ms = edFiberAPdur.Value;
        cfg.fibers.sigma_i = edFiberSigmaI.Value;
        cfg.fibers.sigma_e = edFiberSigmaE.Value;
        cfg.fibers.temperature = edFiberTemp.Value;
        
        % Диаметры и CV - парсим как массивы
        try
            cfg.fibers.diam_range_um = eval(edFiberDiam.Value);
            cfg.fibers.cv_range = eval(edFiberCV.Value);
        catch
            % Используем defaults при ошибке парсинга
            cfg.fibers.diam_range_um = [35, 50, 65];
            cfg.fibers.cv_range = [3.0, 4.0, 5.0];
        end
        
        % Также обновляем Cm_F_per_m2 для совместимости с ядром
        cfg.fibers.Cm_F_per_m2 = cfg.fibers.Cm_uF_per_cm2 * 0.01;  % мкФ/см² -> Ф/м²
        
        % === MUAP Library параметры ===
        if ~isfield(cfg, 'muap_library')
            cfg.muap_library = struct();
        end
        cfg.muap_library.enabled = cbMUAPLibEnabled.Value;
        cfg.muap_library.n_depth_points = edMUAPDepthPts.Value;
        cfg.muap_library.n_cv_points = edMUAPCVPts.Value;
        cfg.muap_library.n_fat_points = edMUAPFatPts.Value;
        cfg.muap_library.auto_precompute = cbMUAPAutoPrecompute.Value;
        cfg.muap_library.save_after_compute = cbMUAPSaveAfter.Value;
        
        % Simulation
        cfg.simulation.fs_internal = edFsInt.Value;
        cfg.simulation.fs_output = edFsOut.Value;
        cfg.save_data = cbSave.Value;
        cfg.save_path = edSavePath.Value;
        
        cfg = validate_cfg_for_core(cfg);
        set_cfg_cb(cfg);
        delete(fig);
    end
end

%% =========================================================================
% WINDOW 1: GEOMETRY EDITOR
% =========================================================================
function geometry_editor(cfg, set_cfg_cb)
    fig = uifigure('Name','Окно 1: Геометрия сечения','Position',[80 80 1300 780],...
        'AutoResizeChildren','on','Resize','on');

    gl = uigridlayout(fig,[1 2]);
    gl.ColumnWidth = {520,'1x'};
    gl.Padding = [5 5 5 5];

    % ===== Левая часть - вкладки с параметрами =====
    tabs = uitabgroup(gl);
    
    % -------------------- ВКЛАДКА 1: Слои тканей --------------------
    tab1 = uitab(tabs,'Title','Слои тканей');
    pgl1 = uigridlayout(tab1,[10 2]);
    pgl1.ColumnWidth = {220,'1x'};
    pgl1.RowHeight = repmat({32},1,10);
    
    row = 1;
    lab1(pgl1,'Длина цилиндра L (м)',row,1);
    edLen = uieditfield(pgl1,'numeric','Value',cfg.geometry.length,'Limits',[0.01 5]);
    place1(edLen,row,2); row=row+1;
    
    lab1(pgl1,'Внешний радиус (м)',row,1);
    edR = uieditfield(pgl1,'numeric','Value',cfg.geometry.radius_outer,'Limits',[0.005 0.2]);
    place1(edR,row,2); row=row+1;
    
    lab1(pgl1,'Толщина кожи (м)',row,1);
    edSkin = uieditfield(pgl1,'numeric','Value',cfg.geometry.skin_thickness,'Limits',[0 0.02]);
    place1(edSkin,row,2); row=row+1;
    
    lab1(pgl1,'Толщина жира (м)',row,1);
    edFat = uieditfield(pgl1,'numeric','Value',cfg.geometry.fat_thickness,'Limits',[0 0.05]);
    place1(edFat,row,2); row=row+1;
    
    lab1(pgl1,'Толщина фасции (м)',row,1);
    edFas = uieditfield(pgl1,'numeric','Value',cfg.geometry.fascia_thickness,'Limits',[0 0.01]);
    place1(edFas,row,2); row=row+1;
    
    % Информация о радиусах слоёв
    lblInfo = uilabel(pgl1,'Text','');
    lblInfo.Layout.Row = [6 8]; lblInfo.Layout.Column = [1 2];
    
    % -------------------- ВКЛАДКА 2: Кости --------------------
    tab2 = uitab(tabs,'Title','Кости');
    pgl2 = uigridlayout(tab2,[10 2]);
    pgl2.ColumnWidth = {220,'1x'};
    rh2 = repmat({32},1,10);
    rh2{1} = 140;  % таблица костей
    pgl2.RowHeight = rh2;
    
    % Таблица костей
    bonesTbl = uitable(pgl2,'Data',[cfg.geometry.bones.positions cfg.geometry.bones.radii(:)], ...
        'ColumnName',{'X (м)','Y (м)','Радиус (м)'},'ColumnEditable',[true true true],'RowName',[]);
    bonesTbl.Layout.Row = 1; bonesTbl.Layout.Column = [1 2];
    bonesTbl.Data = pad_bones(bonesTbl.Data);
    bonesTbl.CellEditCallback = @(s,e)refresh();
    
    btnAddBone = uibutton(pgl2,'Text','+ Добавить кость','ButtonPushedFcn',@(s,e)add_bone());
    btnAddBone.Layout.Row = 2; btnAddBone.Layout.Column = 1;
    btnDelBone = uibutton(pgl2,'Text','- Удалить кость','ButtonPushedFcn',@(s,e)del_bone());
    btnDelBone.Layout.Row = 2; btnDelBone.Layout.Column = 2;
    
    lab1(pgl2,'Активная кость',3,1);
    ddBone = uidropdown(pgl2,'Items',compose("Кость %d",1:size(bonesTbl.Data,1)),'Value',"Кость 1");
    ddBone.Layout.Row = 3; ddBone.Layout.Column = 2;
    
    lab1(pgl2,'Координата X (м)',4,1);
    edBoneX = uieditfield(pgl2,'numeric','Value',bonesTbl.Data(1,1),'Limits',[-0.2 0.2]);
    place1(edBoneX,4,2);
    
    lab1(pgl2,'Координата Y (м)',5,1);
    edBoneY = uieditfield(pgl2,'numeric','Value',bonesTbl.Data(1,2),'Limits',[-0.2 0.2]);
    place1(edBoneY,5,2);
    
    lab1(pgl2,'Радиус кости (м)',6,1);
    edBoneR = uieditfield(pgl2,'numeric','Value',bonesTbl.Data(1,3),'Limits',[1e-4 0.1]);
    place1(edBoneR,6,2);
    
    ddBone.ValueChangedFcn = @(s,e)on_select_bone();
    edBoneX.ValueChangedFcn = @(s,e)write_bone_fields();
    edBoneY.ValueChangedFcn = @(s,e)write_bone_fields();
    edBoneR.ValueChangedFcn = @(s,e)write_bone_fields();
    
    % -------------------- ВКЛАДКА 3: Мышцы --------------------
    tab3 = uitab(tabs,'Title','Мышцы');
    pgl3 = uigridlayout(tab3,[20 2]);
    pgl3.ColumnWidth = {220,'1x'};
    pgl3.RowHeight = repmat({28},1,20);
    
    row = 1;
    lab1(pgl3,'Активная мышца',row,1);
    lst = uidropdown(pgl3,'Items',muscle_names(cfg),'Value',cfg.muscles{1}.name);
    lst.Layout.Row = row; lst.Layout.Column = 2; row=row+1;
    
    btnAddM = uibutton(pgl3,'Text','+ Добавить мышцу','ButtonPushedFcn',@(s,e)add_muscle());
    btnAddM.Layout.Row = row; btnAddM.Layout.Column = 1;
    btnDelM = uibutton(pgl3,'Text','- Удалить мышцу','ButtonPushedFcn',@(s,e)del_muscle());
    btnDelM.Layout.Row = row; btnDelM.Layout.Column = 2; row=row+1;
    
    lab1(pgl3,'--- Основные параметры ---',row,1);
    row=row+1;
    
    lab1(pgl3,'Название мышцы',row,1);
    edMuscleName = uieditfield(pgl3,'text','Value',cfg.muscles{1}.name);
    place1(edMuscleName,row,2); row=row+1;
    
    lab1(pgl3,'Угол положения (град)',row,1);
    edAng = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.position_angle,'Limits',[-180 180]);
    place1(edAng,row,2); row=row+1;
    
    lab1(pgl3,'Глубина от центра (м)',row,1);
    edDepth = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.depth,'Limits',[0 0.1]);
    place1(edDepth,row,2); row=row+1;
    
    lab1(pgl3,'Площадь сечения (см²)',row,1);
    edArea = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.cross_section_area*1e4,'Limits',[0.1 200]);
    place1(edArea,row,2); row=row+1;
    
    lab1(pgl3,'Длина волокон (м)',row,1);
    edFL = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.fiber_length,'Limits',[0.01 1]);
    place1(edFL,row,2); row=row+1;
    
    lab1(pgl3,'Удельная сила σ (Н/см²)',row,1);
    edSigma = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.sigma,'Limits',[1 100]);
    place1(edSigma,row,2); row=row+1;
    
    lab1(pgl3,'Число моторных единиц',row,1);
    edNMU = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.n_motor_units,'Limits',[1 5000],'RoundFractionalValues','on');
    place1(edNMU,row,2); row=row+1;
    
    lab1(pgl3,'Фасция мышцы (м)',row,1);
    edMFas = uieditfield(pgl3,'numeric','Value',cfg.muscles{1}.fascia_thickness,'Limits',[0 0.01]);
    place1(edMFas,row,2); row=row+1;
    
    lab1(pgl3,'--- Форма эллипса ---',row,1);
    row=row+1;
    
    lab1(pgl3,'Соотношение осей (a/b)',row,1);
    edAspect = uieditfield(pgl3,'numeric','Value',get_mfield(cfg.muscles{1},'ellipse_aspect',1.5),'Limits',[0.2 5]);
    place1(edAspect,row,2); row=row+1;
    
    lab1(pgl3,'Поворот эллипса (град)',row,1);
    edEllAng = uieditfield(pgl3,'numeric','Value',get_mfield(cfg.muscles{1},'ellipse_angle',0),'Limits',[-180 180]);
    place1(edEllAng,row,2); row=row+1;
    
    lab1(pgl3,'--- Полигон (опционально) ---',row,1);
    row=row+1;
    
    lab1(pgl3,'Число точек полигона',row,1);
    edPolyPoints = uieditfield(pgl3,'numeric','Value',8,'Limits',[3 50],'RoundFractionalValues','on');
    place1(edPolyPoints,row,2); row=row+1;
    
    btnPoly = uibutton(pgl3,'Text','Создать/редактировать полигон','ButtonPushedFcn',@(s,e)edit_polygon());
    btnPoly.Layout.Row = row; btnPoly.Layout.Column = 1;
    btnResetPolyMain = uibutton(pgl3,'Text','Сбросить до эллипса','ButtonPushedFcn',@(s,e)reset_polygon(),'BackgroundColor',[0.9 0.7 0.4]);
    btnResetPolyMain.Layout.Row = row; btnResetPolyMain.Layout.Column = 2; row=row+1;
    
    % Статус полигона
    lblPolyStatus = uilabel(pgl3,'Text','Форма: эллипс','FontSize',10,'FontColor',[0.3 0.3 0.3]);
    lblPolyStatus.Layout.Row = row; lblPolyStatus.Layout.Column = [1 2]; row=row+1;
    
    % Отображение F_max
    lblFmax = uilabel(pgl3,'Text','F_max = ...','FontWeight','bold');
    lblFmax.Layout.Row = row; lblFmax.Layout.Column = [1 2];
    
    % -------------------- ВКЛАДКА 4: Распределение ДЕ --------------------
    tab4 = uitab(tabs,'Title','Распределение ДЕ');
    pgl4 = uigridlayout(tab4,[8 2]);
    pgl4.ColumnWidth = {220,'1x'};
    pgl4.RowHeight = repmat({32},1,8);
    
    row = 1;
    lab1(pgl4,'Пространственное распределение',row,1);
    ddMUSpatial = uidropdown(pgl4,'Items',{'uniform','clustered','radial_gradient'},'Value','uniform');
    place1(ddMUSpatial,row,2); row=row+1;
    
    lab1(pgl4,'Распределение типов ДЕ',row,1);
    ddMUType = uidropdown(pgl4,'Items',{'size_principle','random','inverse'},'Value','size_principle');
    place1(ddMUType,row,2); row=row+1;
    
    % Загрузка текущих значений если есть
    if ~isempty(cfg.muscles)
        mu_dist = getf(cfg.muscles{1},'mu_distribution',struct());
        sp = getf(mu_dist,'spatial','uniform');
        tg = getf(mu_dist,'type_gradient','size_principle');
        if any(strcmp(ddMUSpatial.Items, sp)), ddMUSpatial.Value = sp; end
        if any(strcmp(ddMUType.Items, tg)), ddMUType.Value = tg; end
    end
    
    lblMUInfo = uilabel(pgl4,'Text','');
    lblMUInfo.Layout.Row = [3 6]; lblMUInfo.Layout.Column = [1 2];
    update_mu_info();
    
    % -------------------- ВКЛАДКА 5: Полигон мышцы --------------------
    tab5 = uitab(tabs,'Title','Полигон');
    pgl5 = uigridlayout(tab5,[10 2]);
    pgl5.ColumnWidth = {180,'1x'};
    rh5 = repmat({28},1,10);
    rh5{3} = 180;  % таблица точек
    pgl5.RowHeight = rh5;
    
    lab1(pgl5,'Точки полигона мышцы',1,1);
    lblPolyInfo = uilabel(pgl5,'Text','(Относительно центра мышцы)','FontSize',10);
    lblPolyInfo.Layout.Row = 1; lblPolyInfo.Layout.Column = 2;
    
    lab1(pgl5,'Формат: X, Y в метрах',2,1);
    
    % Таблица точек полигона
    polyTbl = uitable(pgl5,'Data',zeros(0,2),'ColumnName',{'X (м)','Y (м)'},...
        'ColumnEditable',[true true],'RowName',[],'ColumnFormat',{'numeric','numeric'});
    polyTbl.Layout.Row = 3; polyTbl.Layout.Column = [1 2];
    
    % Загрузка текущего полигона
    if ~isempty(cfg.muscles) && isfield(cfg.muscles{1},'polygon') && ~isempty(cfg.muscles{1}.polygon)
        polyTbl.Data = cfg.muscles{1}.polygon;
    end
    
    btnAddPoint = uibutton(pgl5,'Text','+ Точка','ButtonPushedFcn',@(s,e)add_poly_point());
    btnAddPoint.Layout.Row = 4; btnAddPoint.Layout.Column = 1;
    btnDelPoint = uibutton(pgl5,'Text','- Точка','ButtonPushedFcn',@(s,e)del_poly_point());
    btnDelPoint.Layout.Row = 4; btnDelPoint.Layout.Column = 2;
    
    btnResetPoly = uibutton(pgl5,'Text','Сбросить до эллипса','ButtonPushedFcn',@(s,e)reset_polygon(),'BackgroundColor',[0.9 0.7 0.4]);
    btnResetPoly.Layout.Row = 5; btnResetPoly.Layout.Column = [1 2];
    
    btnApplyPoly = uibutton(pgl5,'Text','Применить полигон','ButtonPushedFcn',@(s,e)apply_polygon(),'BackgroundColor',[0.5 0.7 0.9]);
    btnApplyPoly.Layout.Row = 6; btnApplyPoly.Layout.Column = [1 2];
    
    % -------------------- ВКЛАДКА 6: Проверка геометрии --------------------
    tab6 = uitab(tabs,'Title','Проверка');
    pgl6 = uigridlayout(tab6,[8 2]);
    pgl6.ColumnWidth = {'1x','1x'};
    pgl6.RowHeight = repmat({32},1,8);
    
    btnCheckOverlap = uibutton(pgl6,'Text','Проверить наложение','ButtonPushedFcn',@(s,e)check_overlap(),'BackgroundColor',[0.8 0.8 0.3]);
    btnCheckOverlap.Layout.Row = 1; btnCheckOverlap.Layout.Column = [1 2];
    
    btnAutoFix = uibutton(pgl6,'Text','Автокоррекция наложений','ButtonPushedFcn',@(s,e)auto_fix_overlaps(),'BackgroundColor',[0.9 0.6 0.3]);
    btnAutoFix.Layout.Row = 2; btnAutoFix.Layout.Column = [1 2];
    
    lblCheckResult = uilabel(pgl6,'Text','Нажмите "Проверить наложение" для анализа геометрии.');
    lblCheckResult.Layout.Row = [3 8]; lblCheckResult.Layout.Column = [1 2];
    
    % ===== Правая часть - визуализация =====
    pnlVis = uipanel(gl,'Title','Предпросмотр сечения');
    visGL = uigridlayout(pnlVis,[2 1]);
    visGL.RowHeight = {'1x', 40};
    
    ax = uiaxes(visGL);
    ax.Layout.Row = 1;
    ax.DataAspectRatio = [1 1 1];
    ax.XGrid = 'on'; ax.YGrid = 'on';
    title(ax,'Поперечное сечение');
    xlabel(ax,'X (м)'); ylabel(ax,'Y (м)');
    
    % Кнопки внизу
    ctrlGL = uigridlayout(visGL,[1 3]);
    ctrlGL.Layout.Row = 2;
    ctrlGL.ColumnWidth = {'1x','1x','1x'};
    
    btnRefresh = uibutton(ctrlGL,'Text','Обновить','ButtonPushedFcn',@(s,e)refresh());
    btnCheckQuick = uibutton(ctrlGL,'Text','Проверить','ButtonPushedFcn',@(s,e)check_overlap(),'BackgroundColor',[0.9 0.85 0.6]);
    btnApply = uibutton(ctrlGL,'Text','Применить и закрыть','ButtonPushedFcn',@(s,e)on_close(),'BackgroundColor',[0.3 0.8 0.3]);
    
    % ===== Привязка обработчиков =====
    edLen.ValueChangedFcn = @(s,e)refresh();
    edR.ValueChangedFcn   = @(s,e)refresh();
    edSkin.ValueChangedFcn= @(s,e)refresh();
    edFat.ValueChangedFcn = @(s,e)refresh();
    edFas.ValueChangedFcn = @(s,e)refresh();

    lst.ValueChangedFcn = @(s,e)on_select_muscle();
    edMuscleName.ValueChangedFcn = @(s,e)write_muscle();
    edAng.ValueChangedFcn   = @(s,e)write_muscle();
    edDepth.ValueChangedFcn = @(s,e)write_muscle();
    edArea.ValueChangedFcn  = @(s,e)write_muscle();
    edFL.ValueChangedFcn    = @(s,e)write_muscle();
    edSigma.ValueChangedFcn = @(s,e)write_muscle();
    edNMU.ValueChangedFcn   = @(s,e)write_muscle();
    edMFas.ValueChangedFcn  = @(s,e)write_muscle();
    edAspect.ValueChangedFcn = @(s,e)write_muscle();
    edEllAng.ValueChangedFcn = @(s,e)write_muscle();
    ddMUSpatial.ValueChangedFcn = @(s,e)write_muscle();
    ddMUType.ValueChangedFcn = @(s,e)write_muscle();

    % Инициализация
    setappdata(fig,'cfg_local',cfg);
    on_select_bone();
    refresh();
    update_layer_info();
    update_fmax();

    % ===== Вспомогательные функции =====
    function lab1(parent, text, r, c)
        lbl = uilabel(parent,'Text',text);
        lbl.Layout.Row = r; lbl.Layout.Column = c;
    end
    function place1(comp, r, c)
        comp.Layout.Row = r; comp.Layout.Column = c;
    end
    
    function update_layer_info()
        Rskin = edR.Value;
        Rfat  = Rskin - edSkin.Value;
        Rfas  = Rfat  - edFat.Value;
        Rmus  = Rfas  - edFas.Value;
        lblInfo.Text = sprintf(['Радиусы слоёв:\n' ...
            '• Кожа (внешний): %.4f м\n' ...
            '• Жир: %.4f м\n' ...
            '• Фасция: %.4f м\n' ...
            '• Мышечная область: %.4f м'], Rskin, Rfat, Rfas, Rmus);
    end
    
    function update_fmax()
        area_cm2 = edArea.Value;
        sigma = edSigma.Value;
        F_max = sigma * area_cm2;  % N
        lblFmax.Text = sprintf('F_max = %.1f Н (σ × S)', F_max);
    end
    
    function update_mu_info()
        lblMUInfo.Text = sprintf(['Описание распределений:\n\n' ...
            'Пространственное:\n' ...
            '• uniform - равномерно по площади\n' ...
            '• clustered - кластеры по типам\n' ...
            '• radial_gradient - радиальный градиент\n\n' ...
            'Типы ДЕ:\n' ...
            '• size_principle - S в центре, FF на периферии\n' ...
            '• random - случайное распределение\n' ...
            '• inverse - FF в центре, S на периферии']);
    end

    % ===== Функции работы с полигоном =====
    function add_poly_point()
        D = polyTbl.Data;
        if isempty(D)
            D = [0 0];
        else
            D(end+1,:) = [0 0];
        end
        polyTbl.Data = D;
    end
    
    function del_poly_point()
        D = polyTbl.Data;
        if size(D,1) > 0
            D(end,:) = [];
            polyTbl.Data = D;
        end
    end
    
    function reset_polygon()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        if isempty(idx), return; end
        
        % Очистить полигон - будет использоваться эллипс
        cfg.muscles{idx}.polygon = [];
        polyTbl.Data = zeros(0,2);
        setcfg(cfg);
        update_poly_status();
        refresh();
    end
    
    function update_poly_status()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        if isempty(idx), return; end
        m = cfg.muscles{idx};
        
        if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
            lblPolyStatus.Text = sprintf('Форма: полигон (%d точек)', size(m.polygon,1));
            lblPolyStatus.FontColor = [0 0.5 0];
        else
            lblPolyStatus.Text = 'Форма: эллипс';
            lblPolyStatus.FontColor = [0.3 0.3 0.3];
        end
    end
    
    function apply_polygon()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        if isempty(idx), return; end
        
        D = polyTbl.Data;
        if size(D,1) < 3
            uialert(fig,'Полигон должен содержать минимум 3 точки.','Ошибка');
            return;
        end
        
        % Убираем NaN
        valid = all(isfinite(D),2);
        D = D(valid,:);
        
        if size(D,1) < 3
            uialert(fig,'Недостаточно валидных точек.','Ошибка');
            return;
        end
        
        cfg.muscles{idx}.polygon = D;
        polyTbl.Data = D;
        setcfg(cfg);
        refresh();
    end
    
    function update_poly_table()
        % Обновить таблицу полигона при смене мышцы
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        if isempty(idx), return; end
        m = cfg.muscles{idx};
        
        if isfield(m,'polygon') && ~isempty(m.polygon)
            polyTbl.Data = m.polygon;
        else
            polyTbl.Data = zeros(0,2);
        end
    end

    % ===== Функции проверки наложения =====
    function check_overlap()
        cfg = getcfg();
        problems = {};
        warnings = {};
        
        Rskin = cfg.geometry.radius_outer;
        Rfat  = Rskin - cfg.geometry.skin_thickness;
        Rfas  = Rfat  - cfg.geometry.fat_thickness;
        Rmus  = Rfas  - cfg.geometry.fascia_thickness;
        
        % Проверка радиусов слоёв
        if Rfat <= 0
            problems{end+1} = '❌ Радиус жира <= 0 (толщина кожи слишком большая)';
        end
        if Rfas <= 0
            problems{end+1} = '❌ Радиус фасции <= 0 (толщина жира слишком большая)';
        end
        if Rmus <= 0
            problems{end+1} = '❌ Радиус мышечной области <= 0';
        end
        
        % Проверка костей
        for b = 1:size(cfg.geometry.bones.positions,1)
            bx = cfg.geometry.bones.positions(b,1);
            by = cfg.geometry.bones.positions(b,2);
            br = cfg.geometry.bones.radii(b);
            bone_dist = sqrt(bx^2 + by^2);
            
            % Кость должна быть внутри мышечной области
            if bone_dist + br > Rmus
                problems{end+1} = sprintf('❌ Кость %d выходит за пределы мышечной области', b);
            end
            
            % Проверка пересечения костей между собой
            for b2 = b+1:size(cfg.geometry.bones.positions,1)
                bx2 = cfg.geometry.bones.positions(b2,1);
                by2 = cfg.geometry.bones.positions(b2,2);
                br2 = cfg.geometry.bones.radii(b2);
                dist_bones = sqrt((bx-bx2)^2 + (by-by2)^2);
                if dist_bones < br + br2
                    problems{end+1} = sprintf('❌ Кости %d и %d пересекаются', b, b2);
                end
            end
        end
        
        % Проверка мышц
        for k = 1:numel(cfg.muscles)
            m = cfg.muscles{k};
            [cx, cy] = muscle_center_xy(m);
            [area, eff_radius, bbox] = muscle_geometry(m);
            muscle_dist = sqrt(cx^2 + cy^2);
            
            % Определяем тип формы для сообщений
            has_poly = isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3;
            shape_str = '';
            if has_poly
                shape_str = sprintf(' [полигон, S=%.2f см²]', area*1e4);
            end
            
            % Центр мышцы должен быть внутри мышечной области
            if muscle_dist > Rmus
                problems{end+1} = sprintf('❌ Центр мышцы "%s"%s вне мышечной области', m.name, shape_str);
            end
            
            % Мышца не должна выходить за пределы мышечной области
            % Проверяем по bounding box
            max_extent = max([abs(bbox(1)), abs(bbox(2)), abs(bbox(3)), abs(bbox(4))]);
            if max_extent > Rmus * 1.05
                warnings{end+1} = sprintf('⚠️ Мышца "%s"%s выходит за пределы мышечной области', m.name, shape_str);
            elseif muscle_dist + eff_radius > Rmus * 1.1
                warnings{end+1} = sprintf('⚠️ Мышца "%s"%s может выходить за пределы', m.name, shape_str);
            end
            
            % Проверка пересечения мышц с костями
            for b = 1:size(cfg.geometry.bones.positions,1)
                bx = cfg.geometry.bones.positions(b,1);
                by = cfg.geometry.bones.positions(b,2);
                br = cfg.geometry.bones.radii(b);
                
                if has_poly
                    % Для полигона проверяем, не попадает ли кость внутрь
                    ang = m.position_angle*pi/180;
                    base_cx = m.depth*cos(ang);
                    base_cy = m.depth*sin(ang);
                    poly_abs_x = m.polygon(:,1) + base_cx;
                    poly_abs_y = m.polygon(:,2) + base_cy;
                    
                    % Проверяем центр кости
                    if inpolygon(bx, by, poly_abs_x, poly_abs_y)
                        problems{end+1} = sprintf('❌ Кость %d находится внутри мышцы "%s"', b, m.name);
                    else
                        % Проверяем минимальное расстояние от кости до границы полигона
                        min_dist = min_dist_point_to_polygon(bx, by, poly_abs_x, poly_abs_y);
                        if min_dist < br
                            problems{end+1} = sprintf('❌ Мышца "%s" пересекается с костью %d', m.name, b);
                        end
                    end
                else
                    % Для эллипса - простая проверка по расстоянию
                    dist_to_bone = sqrt((cx-bx)^2 + (cy-by)^2);
                    if dist_to_bone < eff_radius + br
                        problems{end+1} = sprintf('❌ Мышца "%s" пересекается с костью %d', m.name, b);
                    end
                end
            end
            
            % Проверка пересечения мышц между собой
            for k2 = k+1:numel(cfg.muscles)
                m2 = cfg.muscles{k2};
                [cx2, cy2] = muscle_center_xy(m2);
                [~, eff_radius2, ~] = muscle_geometry(m2);
                
                dist_muscles = sqrt((cx-cx2)^2 + (cy-cy2)^2);
                if dist_muscles < (eff_radius + eff_radius2) * 0.7
                    warnings{end+1} = sprintf('⚠️ Мышцы "%s" и "%s" могут пересекаться', m.name, m2.name);
                end
            end
        end
        
        % Формируем результат
        result_text = '';
        if isempty(problems) && isempty(warnings)
            result_text = '✅ Геометрия корректна!\n\nНет проблем с наложением тканей, костей и мышц.';
        else
            if ~isempty(problems)
                result_text = sprintf('ОШИБКИ:\n%s\n\n', strjoin(problems, '\n'));
            end
            if ~isempty(warnings)
                result_text = [result_text sprintf('ПРЕДУПРЕЖДЕНИЯ:\n%s', strjoin(warnings, '\n'))];
            end
        end
        
        lblCheckResult.Text = sprintf(result_text);
    end
    
    function auto_fix_overlaps()
        cfg = getcfg();
        fixed = {};
        
        Rskin = cfg.geometry.radius_outer;
        Rfat  = Rskin - cfg.geometry.skin_thickness;
        Rfas  = Rfat  - cfg.geometry.fat_thickness;
        Rmus  = Rfas  - cfg.geometry.fascia_thickness;
        
        % Исправление мышц, пересекающихся с костями
        for k = 1:numel(cfg.muscles)
            m = cfg.muscles{k};
            [cx, cy] = muscle_center_xy(m);
            area = max(m.cross_section_area, eps);
            muscle_r = sqrt(area / pi);
            
            for b = 1:size(cfg.geometry.bones.positions,1)
                bx = cfg.geometry.bones.positions(b,1);
                by = cfg.geometry.bones.positions(b,2);
                br = cfg.geometry.bones.radii(b);
                
                dist_to_bone = sqrt((cx-bx)^2 + (cy-by)^2);
                min_dist = muscle_r + br + 0.002;  % минимальный зазор 2мм
                
                if dist_to_bone < min_dist && dist_to_bone > 0
                    % Сдвигаем мышцу от кости
                    dx = cx - bx;
                    dy = cy - by;
                    d = sqrt(dx^2 + dy^2);
                    
                    % Новый центр мышцы
                    new_cx = bx + dx/d * min_dist;
                    new_cy = by + dy/d * min_dist;
                    
                    % Пересчитываем угол и глубину
                    new_depth = sqrt(new_cx^2 + new_cy^2);
                    new_angle = atan2(new_cy, new_cx) * 180/pi;
                    
                    cfg.muscles{k}.depth = new_depth;
                    cfg.muscles{k}.position_angle = new_angle;
                    
                    fixed{end+1} = sprintf('Мышца "%s" сдвинута от кости %d', m.name, b);
                end
            end
            
            % Проверка что мышца внутри мышечной области
            [cx, cy] = muscle_center_xy(cfg.muscles{k});
            muscle_dist = sqrt(cx^2 + cy^2);
            
            if muscle_dist + muscle_r > Rmus - 0.002
                % Сдвигаем к центру
                max_depth = Rmus - muscle_r - 0.002;
                if max_depth > 0
                    cfg.muscles{k}.depth = min(cfg.muscles{k}.depth, max_depth);
                    fixed{end+1} = sprintf('Мышца "%s" сдвинута внутрь', cfg.muscles{k}.name);
                end
            end
        end
        
        if ~isempty(fixed)
            setcfg(cfg);
            on_select_muscle();
            refresh();
            lblCheckResult.Text = sprintf('Исправлено:\n%s\n\nПроверьте результат визуально.', strjoin(fixed, '\n'));
        else
            lblCheckResult.Text = 'Автокоррекция не потребовалась.';
        end
        
        % Повторная проверка
        check_overlap();
    end

    function on_select_muscle()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        if isempty(idx), idx = 1; end
        m = cfg.muscles{idx};
        edMuscleName.Value = m.name;
        edAng.Value = m.position_angle;
        edDepth.Value = m.depth;
        edArea.Value = m.cross_section_area*1e4;
        edFL.Value = m.fiber_length;
        edSigma.Value = m.sigma;
        edNMU.Value = m.n_motor_units;
        if isfield(m,'fascia_thickness'), edMFas.Value = m.fascia_thickness; else, edMFas.Value = 0.0003; end
        edAspect.Value = get_mfield(m,'ellipse_aspect',1.5);
        edEllAng.Value = get_mfield(m,'ellipse_angle',0);
        
        % Распределение ДЕ
        mu_dist = getf(m,'mu_distribution',struct());
        sp = getf(mu_dist,'spatial','uniform');
        tg = getf(mu_dist,'type_gradient','size_principle');
        if any(strcmp(ddMUSpatial.Items, sp)), ddMUSpatial.Value = sp; end
        if any(strcmp(ddMUType.Items, tg)), ddMUType.Value = tg; end
        
        % Обновить таблицу полигона и статус
        update_poly_table();
        update_poly_status();
        
        update_fmax();
        refresh();
    end

    function add_muscle()
        cfg = getcfg();
        nm = numel(cfg.muscles)+1;
        cfg.muscles{nm} = default_muscle(sprintf('Мышца_%d',nm), 30*(nm-1));
        lst.Items = muscle_names(cfg);
        lst.Value = cfg.muscles{nm}.name;
        setcfg(cfg);
        on_select_muscle();
    end

    function del_muscle()
        cfg = getcfg();
        if numel(cfg.muscles) <= 1
            uialert(fig,'Нельзя удалить последнюю мышцу.','Предупреждение'); return;
        end
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        cfg.muscles(idx) = [];
        lst.Items = muscle_names(cfg);
        lst.Value = cfg.muscles{max(1,min(idx,numel(cfg.muscles)))}.name;
        setcfg(cfg);
        on_select_muscle();
    end

    function add_bone()
        D = bonesTbl.Data;
        D(end+1,:) = [0 0 0.006];
        bonesTbl.Data = pad_bones(D);
        ddBone.Items = compose("Кость %d",1:size(bonesTbl.Data,1));
        ddBone.Value = ddBone.Items{end};
        on_select_bone();
        refresh();
    end

    function del_bone()
        D = bonesTbl.Data;
        if size(D,1) <= 1
            uialert(fig,'Нельзя удалить последнюю кость.','Предупреждение'); return;
        end
        D(end,:) = [];
        bonesTbl.Data = pad_bones(D);
        ddBone.Items = compose("Кость %d",1:size(bonesTbl.Data,1));
        ddBone.Value = ddBone.Items{end};
        on_select_bone();
        refresh();
    end

    function on_select_bone()
        D = bonesTbl.Data;
        nb = size(D,1);
        ddBone.Items = compose("Кость %d",1:nb);
        val = ddBone.Value;
        idx = sscanf(val,'Кость %d');
        if isempty(idx) || idx<1 || idx>nb, idx=1; ddBone.Value = "Кость 1"; end
        edBoneX.Value = D(idx,1);
        edBoneY.Value = D(idx,2);
        edBoneR.Value = D(idx,3);
    end

    function write_bone_fields()
        D = bonesTbl.Data;
        nb = size(D,1);
        val = ddBone.Value;
        idx = sscanf(val,'Кость %d');
        if isempty(idx) || idx<1 || idx>nb, idx=1; ddBone.Value = "Кость 1"; end
        D(idx,1) = edBoneX.Value;
        D(idx,2) = edBoneY.Value;
        D(idx,3) = max(edBoneR.Value, 1e-4);
        bonesTbl.Data = D;
        refresh();
    end

    function write_muscle()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        if isempty(idx), return; end
        m = cfg.muscles{idx};
        old_name = m.name;
        m.name = edMuscleName.Value;
        m.position_angle = edAng.Value;
        m.depth = edDepth.Value;
        m.cross_section_area = max(edArea.Value, eps) * 1e-4; % cm2 -> m2
        m.fiber_length = edFL.Value;
        m.sigma = edSigma.Value;
        m.n_motor_units = max(1, round(edNMU.Value));
        m.fascia_thickness = edMFas.Value;
        m.ellipse_aspect = edAspect.Value;
        m.ellipse_angle = edEllAng.Value;
        
        % Распределение ДЕ
        m.mu_distribution.spatial = ddMUSpatial.Value;
        m.mu_distribution.type_gradient = ddMUType.Value;
        
        cfg.muscles{idx} = m;
        
        % Обновить dropdown если имя изменилось
        if ~strcmp(old_name, m.name)
            lst.Items = muscle_names(cfg);
            lst.Value = m.name;
        end
        
        setcfg(cfg);
        update_fmax();
        refresh();
    end

    function edit_polygon()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), lst.Value), 1);
        m = cfg.muscles{idx};
        
        n_poly_points = round(edPolyPoints.Value);
        
        % Базовый центр мышцы (полигон хранится относительно него)
        ang_m = m.position_angle*pi/180;
        base_cx = m.depth*cos(ang_m);
        base_cy = m.depth*sin(ang_m);

        if exist('drawpolygon','file') == 2
            refresh();
            hold(ax,'on');
            try
                % Если уже есть полигон, используем его, иначе создаём из эллипса
                if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
                    init_pos = m.polygon + [base_cx, base_cy];
                else
                    % Создаём начальный полигон из эллипса с заданным числом точек
                    area = max(m.cross_section_area, eps);
                    aspect = get_mfield(m,'ellipse_aspect',1.5);
                    a = sqrt(area*aspect/pi);
                    b = sqrt(area/(pi*aspect));
                    ang = get_mfield(m,'ellipse_angle',0) * pi/180;
                    
                    th = linspace(0, 2*pi, n_poly_points+1);
                    th = th(1:end-1);  % Убираем последнюю (дублирующую) точку
                    xr = a*cos(th);
                    yr = b*sin(th);
                    x = xr*cos(ang) - yr*sin(ang);
                    y = xr*sin(ang) + yr*cos(ang);
                    init_pos = [base_cx + x(:), base_cy + y(:)];
                end
                
                h = drawpolygon(ax,'Position',init_pos);
                try
                    wait(h);
                catch
                    uiwait(msgbox('Завершите полигон двойным кликом. Затем закройте это окно.','Полигон','modal'));
                end
                if ~isvalid(h)
                    hold(ax,'off');
                    return;
                end
                P = h.Position;
                delete(h);
                hold(ax,'off');
            catch ME
                if exist('h','var') && isvalid(h), delete(h); end
                hold(ax,'off');
                uialert(fig, sprintf('Ошибка: %s', ME.message), 'Полигон');
                return;
            end

            if isempty(P) || size(P,2)~=2 || size(P,1)<3
                return;
            end
            % Сохраняем полигон в локальных координатах относительно базового центра
            m.polygon = P - [base_cx, base_cy];
            cfg.muscles{idx} = m;
            setcfg(cfg);
            update_poly_status();
            refresh();
        else
            uialert(fig, 'drawpolygon недоступен. Используйте эллипс.', 'Недоступно');
        end
    end

    function on_close()
        cfg = getcfg();
        cfg.geometry.length = edLen.Value;
        cfg.geometry.radius_outer = edR.Value;
        cfg.geometry.skin_thickness = edSkin.Value;
        cfg.geometry.fat_thickness = edFat.Value;
        cfg.geometry.fascia_thickness = edFas.Value;

        D = bonesTbl.Data;
        cfg.geometry.bones.positions = D(:,1:2);
        cfg.geometry.bones.radii = D(:,3)';

        cfg = validate_cfg_for_core(cfg);
        set_cfg_cb(cfg);
        delete(fig);
    end

    function refresh()
        cfg = getcfg();
        cfg.geometry.length = edLen.Value;
        cfg.geometry.radius_outer = edR.Value;
        cfg.geometry.skin_thickness = edSkin.Value;
        cfg.geometry.fat_thickness = edFat.Value;
        cfg.geometry.fascia_thickness = edFas.Value;

        D = bonesTbl.Data;
        cfg.geometry.bones.positions = D(:,1:2);
        cfg.geometry.bones.radii = D(:,3)';

        cla(ax);
        hold(ax,'on');

        Rskin = cfg.geometry.radius_outer;
        Rfat  = Rskin - cfg.geometry.skin_thickness;
        Rfas  = Rfat  - cfg.geometry.fat_thickness;
        Rmus  = Rfas  - cfg.geometry.fascia_thickness;

        % Цвета слоёв (новые):
        % Кожа - бежевый
        % Жир - жёлтый
        % Фасция общая - светло-зелёная
        % Мышечная область - светло-красная/розовая
        col_skin = [0.96 0.87 0.70];    % бежевый
        col_fat  = [1.0 0.95 0.55];     % жёлтый
        col_fas  = [0.85 0.95 0.85];    % светло-зелёный
        col_mus  = [0.95 0.80 0.80];    % светло-красный/розовый
        col_bone = [1.0 1.0 1.0];       % белый
        col_muscle_fill = [0.85 0.45 0.45];  % красный для мышцы
        col_muscle_fas  = [0.75 0.55 0.85];  % фиолетовый для фасции мышцы

        % Слои с заливкой (от внешнего к внутреннему)
        fill_circle(ax,0,0,Rskin,col_skin,0.6);   % кожа
        fill_circle(ax,0,0,Rfat,col_fat,0.7);     % жир
        fill_circle(ax,0,0,Rfas,col_fas,0.5);     % фасция
        fill_circle(ax,0,0,Rmus,col_mus,0.4);     % мышечная область
        
        draw_circle(ax,0,0,Rskin,'k-');
        draw_circle(ax,0,0,Rfat,'k:');
        draw_circle(ax,0,0,Rfas,'k:');
        draw_circle(ax,0,0,Rmus,'k:');

        % Кости - белые
        for b=1:size(cfg.geometry.bones.positions,1)
            x = cfg.geometry.bones.positions(b,1);
            y = cfg.geometry.bones.positions(b,2);
            r = cfg.geometry.bones.radii(b);
            fill_circle(ax,x,y,r,col_bone,0.95);
            draw_circle(ax,x,y,r,'k-');
            text(ax,x,y,sprintf('К%d',b),'FontSize',8,'HorizontalAlignment','center');
        end

        % Мышцы с фасцией и заливкой
        for k=1:numel(cfg.muscles)
            m = cfg.muscles{k};
            
            % Базовый центр мышцы (для смещения полигона)
            ang_m = m.position_angle*pi/180;
            base_cx = m.depth*cos(ang_m);
            base_cy = m.depth*sin(ang_m);
            
            % Центроид мышцы (для подписи)
            [cx,cy] = muscle_center_xy(m);
            
            % Толщина фасции мышцы
            mfas = getf(m,'fascia_thickness',0.0003);
            
            if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
                % Полигон хранится в локальных координатах относительно базового центра
                P = m.polygon + [base_cx, base_cy];
                % Заливка фасции (увеличенный полигон)
                if mfas > 0
                    P_fas = expand_polygon(P, mfas);
                    patch(ax, P_fas(:,1), P_fas(:,2), col_muscle_fas, 'FaceAlpha', 0.6, 'EdgeColor', 'none');
                end
                % Заливка мышцы
                patch(ax, P(:,1), P(:,2), col_muscle_fill, 'FaceAlpha', 0.7, 'EdgeColor', [0.6 0.2 0.2], 'LineWidth', 1.5);
            else
                % Эллипс
                [vx,vy] = muscle_ellipse_vertices(m);
                % Заливка фасции (увеличенный эллипс)
                if mfas > 0
                    [vx_fas, vy_fas] = muscle_ellipse_vertices_with_offset(m, mfas);
                    patch(ax, vx_fas, vy_fas, col_muscle_fas, 'FaceAlpha', 0.6, 'EdgeColor', 'none');
                end
                % Заливка мышцы
                patch(ax, vx, vy, col_muscle_fill, 'FaceAlpha', 0.7, 'EdgeColor', [0.6 0.2 0.2], 'LineWidth', 1.5);
            end
            text(ax,cx,cy, m.name,'FontSize',9,'HorizontalAlignment','center','FontWeight','bold','Color','w');
        end

        % Легенда
        % Создаём невидимые объекты для легенды
        h_skin = patch(ax, nan, nan, col_skin, 'FaceAlpha', 0.6);
        h_fat = patch(ax, nan, nan, col_fat, 'FaceAlpha', 0.7);
        h_bone = patch(ax, nan, nan, col_bone, 'FaceAlpha', 0.95, 'EdgeColor', 'k');
        h_mus = patch(ax, nan, nan, col_muscle_fill, 'FaceAlpha', 0.7);
        h_fas = patch(ax, nan, nan, col_muscle_fas, 'FaceAlpha', 0.6);
        legend(ax, [h_skin h_fat h_bone h_mus h_fas], ...
            {'Кожа','Жир','Кость','Мышца','Фасция мышцы'}, ...
            'Location','northeast','FontSize',8);

        axis(ax,[-Rskin Rskin -Rskin Rskin]*1.15);
        hold(ax,'off');
        
        update_layer_info();
        setcfg(cfg);
    end

    function cfg = getcfg()
        cfg = getappdata(fig,'cfg_local');
        if isempty(cfg)
            error('Internal error: cfg_local not set');
        end
    end

    function setcfg(c)
        setappdata(fig,'cfg_local',c);
    end
end
function D = pad_bones(D)
    if isempty(D), D = [0 0 0.008]; end
    if size(D,2) ~= 3
        D = [D(:,1:2), 0.008*ones(size(D,1),1)];
    end
end

function [cx,cy] = muscle_center_xy(m)
    % Возвращает центр мышцы (центроид для полигона, или базовый центр для эллипса)
    % Базовый центр из position_angle и depth
    ang = m.position_angle*pi/180;
    base_cx = m.depth*cos(ang);
    base_cy = m.depth*sin(ang);
    
    % Если есть полигон, вычисляем центроид
    if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
        poly = m.polygon;  % Локальные координаты относительно базового центра
        [pcx, pcy] = polygon_centroid(poly(:,1), poly(:,2));
        cx = base_cx + pcx;
        cy = base_cy + pcy;
    else
        cx = base_cx;
        cy = base_cy;
    end
end

function [cx, cy] = polygon_centroid(x, y)
    % Вычисляет центроид (центр масс) полигона
    % x, y - координаты вершин полигона
    n = length(x);
    if n < 3
        cx = mean(x);
        cy = mean(y);
        return;
    end
    
    % Формула центроида через площадь
    A = 0;
    cx = 0;
    cy = 0;
    
    for i = 1:n
        j = mod(i, n) + 1;  % следующая вершина (циклически)
        cross_term = x(i)*y(j) - x(j)*y(i);
        A = A + cross_term;
        cx = cx + (x(i) + x(j)) * cross_term;
        cy = cy + (y(i) + y(j)) * cross_term;
    end
    
    A = A / 2;
    if abs(A) < 1e-12
        % Вырожденный полигон - используем среднее
        cx = mean(x);
        cy = mean(y);
    else
        cx = cx / (6 * A);
        cy = cy / (6 * A);
    end
end

function A = polygon_area(x, y)
    % Вычисляет площадь полигона (формула шнурка / Shoelace formula)
    n = length(x);
    if n < 3
        A = 0;
        return;
    end
    
    A = 0;
    for i = 1:n
        j = mod(i, n) + 1;
        A = A + x(i)*y(j) - x(j)*y(i);
    end
    A = abs(A) / 2;
end

function [area, eff_radius, bbox] = muscle_geometry(m)
    % Возвращает геометрические характеристики мышцы:
    % area - площадь (м²)
    % eff_radius - эффективный радиус (м)
    % bbox - bounding box [min_x, max_x, min_y, max_y] в абсолютных координатах
    
    % Базовый центр мышцы
    ang = m.position_angle*pi/180;
    base_cx = m.depth*cos(ang);
    base_cy = m.depth*sin(ang);
    
    if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
        poly = m.polygon;
        % Площадь полигона
        area = polygon_area(poly(:,1), poly(:,2));
        
        % Абсолютные координаты полигона (относительно базового центра)
        abs_x = poly(:,1) + base_cx;
        abs_y = poly(:,2) + base_cy;
        
        % Bounding box
        bbox = [min(abs_x), max(abs_x), min(abs_y), max(abs_y)];
        
        % Центроид в абсолютных координатах
        [pcx, pcy] = polygon_centroid(poly(:,1), poly(:,2));
        centroid_x = base_cx + pcx;
        centroid_y = base_cy + pcy;
        
        % Эффективный радиус = максимальное расстояние от центроида до вершины
        eff_radius = max(sqrt((abs_x - centroid_x).^2 + (abs_y - centroid_y).^2));
    else
        % Эллипс
        area = max(m.cross_section_area, eps);
        eff_radius = sqrt(area / pi);
        
        % Для эллипса вычисляем bbox
        aspect = get_mfield(m,'ellipse_aspect',1.5);
        a = sqrt(area*aspect/pi);  % большая полуось
        b = sqrt(area/(pi*aspect)); % малая полуось
        rot_ang = get_mfield(m,'ellipse_angle',0) * pi/180;
        
        % Приближённый bbox для повёрнутого эллипса
        bbox_r = max(a, b);
        bbox = [base_cx - bbox_r, base_cx + bbox_r, base_cy - bbox_r, base_cy + bbox_r];
    end
end

function d = min_dist_point_to_polygon(px, py, poly_x, poly_y)
    % Вычисляет минимальное расстояние от точки (px, py) до границы полигона
    n = length(poly_x);
    d = inf;
    
    for i = 1:n
        j = mod(i, n) + 1;  % следующая вершина
        
        % Отрезок от вершины i к вершине j
        x1 = poly_x(i); y1 = poly_y(i);
        x2 = poly_x(j); y2 = poly_y(j);
        
        % Вектор отрезка
        dx = x2 - x1;
        dy = y2 - y1;
        
        % Длина отрезка
        len_sq = dx*dx + dy*dy;
        
        if len_sq < 1e-12
            % Вырожденный отрезок (точка)
            dist = sqrt((px - x1)^2 + (py - y1)^2);
        else
            % Проекция точки на отрезок
            t = max(0, min(1, ((px - x1)*dx + (py - y1)*dy) / len_sq));
            
            % Ближайшая точка на отрезке
            nearest_x = x1 + t * dx;
            nearest_y = y1 + t * dy;
            
            dist = sqrt((px - nearest_x)^2 + (py - nearest_y)^2);
        end
        
        d = min(d, dist);
    end
end

function [vx,vy] = muscle_ellipse_vertices(m)
    [cx,cy] = muscle_center_xy(m);
    area = max(m.cross_section_area, eps);
    aspect = get_mfield(m,'ellipse_aspect',1.5);
    a = sqrt(area*aspect/pi);
    b = sqrt(area/(pi*aspect));
    th = linspace(0,2*pi,120);
    ang = get_mfield(m,'ellipse_angle',0) * pi/180;

    xr = a*cos(th);
    yr = b*sin(th);

    x = xr*cos(ang) - yr*sin(ang);
    y = xr*sin(ang) + yr*cos(ang);

    vx = cx + x;
    vy = cy + y;
end

function [vx,vy] = muscle_ellipse_vertices_with_offset(m, offset)
    % Эллипс мышцы с добавленным смещением (для фасции)
    [cx,cy] = muscle_center_xy(m);
    area = max(m.cross_section_area, eps);
    aspect = get_mfield(m,'ellipse_aspect',1.5);
    a = sqrt(area*aspect/pi) + offset;
    b = sqrt(area/(pi*aspect)) + offset;
    th = linspace(0,2*pi,120);
    ang = get_mfield(m,'ellipse_angle',0) * pi/180;

    xr = a*cos(th);
    yr = b*sin(th);

    x = xr*cos(ang) - yr*sin(ang);
    y = xr*sin(ang) + yr*cos(ang);

    vx = cx + x;
    vy = cy + y;
end

function P_out = expand_polygon(P, offset)
    % Расширение полигона на offset (простой метод через смещение от центра)
    cx = mean(P(:,1));
    cy = mean(P(:,2));
    
    n = size(P,1);
    P_out = zeros(n,2);
    
    for i = 1:n
        % Вектор от центра к точке
        dx = P(i,1) - cx;
        dy = P(i,2) - cy;
        d = sqrt(dx^2 + dy^2);
        if d > 0
            % Смещаем точку наружу
            P_out(i,1) = P(i,1) + offset * dx / d;
            P_out(i,2) = P(i,2) + offset * dy / d;
        else
            P_out(i,:) = P(i,:);
        end
    end
end

function draw_circle(ax,cx,cy,r,ls)
    th = linspace(0,2*pi,200);
    plot(ax,cx+r*cos(th),cy+r*sin(th),ls);
end

function draw_circle_adv(ax,cx,cy,r,ls,lw)
    th = linspace(0,2*pi,120);
    plot(ax,cx+r*cos(th),cy+r*sin(th),ls,'LineWidth',lw);
end

function fill_circle(ax,cx,cy,r,face,alpha)
    th = linspace(0,2*pi,240);
    x = cx + r*cos(th);
    y = cy + r*sin(th);
    patch(ax,x,y,face,'EdgeColor','none','FaceAlpha',alpha);
end

function fill_circle_adv(ax,cx,cy,r,face,alpha)
    th = linspace(0,2*pi,120);
    x = cx + r*cos(th);
    y = cy + r*sin(th);
    patch(ax,x,y,face,'EdgeColor','none','FaceAlpha',alpha);
end


function names = muscle_names(cfg)
    names = cell(1,numel(cfg.muscles));
    for k=1:numel(cfg.muscles), names{k} = cfg.muscles{k}.name; end
end




%% =========================================================================
% WINDOW 2: TARGET FORCE EDITOR
% =========================================================================
function targets_editor(cfg, set_cfg_cb)
    fig = uifigure('Name','Окно 2: Целевые силы мышц','Position',[90 90 1400 720],...
        'AutoResizeChildren','on','Resize','on');

    gl = uigridlayout(fig,[1 3]);
    gl.ColumnWidth = {480,'1x','1x'};

    pnl = uipanel(gl,'Title','Редактор профиля силы');
    % Вертикальный layout: верх (параметры + таблица) растягивается, низ (Farina + Apply) фиксирован
    pnlGL = uigridlayout(pnl,[2 1]);
    pnlGL.RowHeight = {'1x', 'fit'};
    pnlGL.ColumnWidth = {'1x'};
    pnlGL.Padding = [0 0 0 0];
    pnlGL.RowSpacing = 2;

    % === ВЕРХНЯЯ ЧАСТЬ: параметры профиля + таблица ===
    pgl = uigridlayout(pnlGL,[19 2]);
    pgl.Layout.Row = 1; pgl.Layout.Column = 1;
    pgl.ColumnWidth = {240,'1x'};
    % 1-13: params (28px), 14: label (22px), 15-17: table (flex), 18-19: buttons
    pgl.RowHeight = [repmat({28},1,13), {22}, {'1x','1x','1x'}, {28, 28}];
    pgl.Padding = [4 4 4 0];

    % === НИЖНЯЯ ЧАСТЬ: Farina + Apply (фиксированная высота) ===
    pglBot = uigridlayout(pnlGL,[7 2]);
    pglBot.Layout.Row = 2; pglBot.Layout.Column = 1;
    pglBot.ColumnWidth = {240,'1x'};
    pglBot.RowHeight = repmat({28},1,7);
    pglBot.Padding = [4 2 4 4];

    % График профиля силы
    ax = uiaxes(gl); ax.XGrid='on'; ax.YGrid='on';
    xlabel(ax,'t (с)'); ylabel(ax,'F_{ref} (Н)');
    title(ax,'Предпросмотр целевой силы');
    
    % График модели Farina (передаточная функция / потенциал)
    axFarina = uiaxes(gl); axFarina.XGrid='on'; axFarina.YGrid='on';
    xlabel(axFarina,'z (мм)'); ylabel(axFarina,'Потенциал (отн. ед.)');
    title(axFarina,'Модель Farina: затухание потенциала');

    ddMuscle = uidropdown(pgl,'Items',muscle_names(cfg),'Value',cfg.muscles{1}.name);
    lab(pgl,'Мышца',1,1); place(ddMuscle,1,2);

    ddMode = uidropdown(pgl,'Items',{'leadfield','farina','fem','both'},'Value',cfg.simulation.solver_mode);
    lab(pgl,'Режим решателя',2,1); place(ddMode,2,2);

    edDur = uieditfield(pgl,'numeric','Value',cfg.simulation.duration,'Limits',[0.01 60]);
    lab(pgl,'Длительность симуляции (с)',3,1); place(edDur,3,2);

    ddType = uidropdown(pgl,'Items',{'ramp_hold','trapezoid','sine','constant','step','pulse','custom'},'Value',cfg.muscles{1}.force_profile.type);
    lab(pgl,'Тип профиля',4,1); place(ddType,4,2);

    % F_max muscle display (auto-calculated)
    m = cfg.muscles{1};
    F_max_muscle = m.sigma * m.cross_section_area * 1e4;  % N
    lblFmaxMuscle = uilabel(pgl,'Text',sprintf('F_max мышцы = %.1f Н', F_max_muscle),'FontWeight','bold');
    lblFmaxMuscle.Layout.Row = 5; lblFmaxMuscle.Layout.Column = [1 2];

    edFmaxPercent = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'F_max_percent',30),'Limits',[0 100]);
    lab(pgl,'F_max (% от максимума)',6,1); place(edFmaxPercent,6,2);

    edFmax = uieditfield(pgl,'numeric','Value',cfg.muscles{1}.force_profile.F_max,'Limits',[0 10000]);
    lab(pgl,'F_max целевая (Н)',7,1); place(edFmax,7,2);

    edRamp = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'ramp_time',0.25),'Limits',[0 10]);
    lab(pgl,'Время нарастания (с)',8,1); place(edRamp,8,2);

    edHold = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'hold_time',0.35),'Limits',[0 10]);
    lab(pgl,'Время удержания (с)',9,1); place(edHold,9,2);

    edDown = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'ramp_down_time',0.25),'Limits',[0 10]);
    lab(pgl,'Время спада (с)',10,1); place(edDown,10,2);

    edStep = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'step_time',0.2),'Limits',[0 10]);
    lab(pgl,'Время ступеньки / начало импульса (с)',11,1); place(edStep,11,2);

    edPulseDur = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'pulse_duration',0.1),'Limits',[0.001 10]);
    lab(pgl,'Длительность импульса (с)',12,1); place(edPulseDur,12,2);

    edFreq = uieditfield(pgl,'numeric','Value',getf(cfg.muscles{1}.force_profile,'frequency',0.5),'Limits',[0 20]);
    lab(pgl,'Частота синуса (Гц)',13,1); place(edFreq,13,2);

    % --- Таблица кастомных точек ---
    lblTbl = uilabel(pgl,'Text','Пользовательские точки [t, F]:','FontAngle','italic');
    lblTbl.Layout.Row = 14; lblTbl.Layout.Column = [1 2];
    
    tbl = uitable(pgl,'Data',zeros(0,2),'ColumnName',{'t (с)','F (Н)'},'ColumnEditable',[true true], 'RowName',[], 'ColumnFormat',{'numeric','numeric'});
    tbl.Layout.Row = [15 17]; tbl.Layout.Column = [1 2];

    btnAddRow = uibutton(pgl,'Text','+ точка','ButtonPushedFcn',@(s,e)add_row());
    btnAddRow.Layout.Row = 18; btnAddRow.Layout.Column = 1;
    btnDelRow = uibutton(pgl,'Text','- точка','ButtonPushedFcn',@(s,e)del_row());
    btnDelRow.Layout.Row = 18; btnDelRow.Layout.Column = 2;

    btnSort = uibutton(pgl,'Text','Сортировать по t','ButtonPushedFcn',@(s,e)sort_points());
    btnSort.Layout.Row = 19; btnSort.Layout.Column = 1;
    btnGen = uibutton(pgl,'Text','Сгенерировать из профиля','ButtonPushedFcn',@(s,e)gen_custom());
    btnGen.Layout.Row = 19; btnGen.Layout.Column = 2;

    % === НИЖНЯЯ ЧАСТЬ (pglBot): Farina + Apply ===
    lblFarinaTitle = uilabel(pglBot,'Text','── Параметры Farina ──','FontWeight','bold');
    lblFarinaTitle.Layout.Row = 1; lblFarinaTitle.Layout.Column = [1 2];
    
    % Получаем текущие параметры Farina
    farina_cfg = struct();
    if isfield(cfg, 'solver') && isfield(cfg.solver, 'farina')
        farina_cfg = cfg.solver.farina;
    end
    
    lab(pglBot,'Точки интегрирования (n_k)',2,1);
    edFarinaNk = uieditfield(pglBot,'numeric','Value',getf(farina_cfg,'n_k_points',64),'Limits',[16 512]);
    place(edFarinaNk,2,2);
    lblFarinaNk = findobj(pglBot.Children,'Type','uilabel','Text','Точки интегрирования (n_k)');
    
    lab(pglBot,'Макс. частота k_max (1/м)',3,1);
    edFarinaKmax = uieditfield(pglBot,'numeric','Value',getf(farina_cfg,'k_max',1500),'Limits',[100 5000]);
    place(edFarinaKmax,3,2);
    lblFarinaKmax = findobj(pglBot.Children,'Type','uilabel','Text','Макс. частота k_max (1/м)');
    
    lab(pglBot,'Члены ряда Бесселя',4,1);
    edFarinaBessel = uieditfield(pglBot,'numeric','Value',getf(farina_cfg,'n_bessel_terms',30),'Limits',[5 100]);
    place(edFarinaBessel,4,2);
    lblFarinaBessel = findobj(pglBot.Children,'Type','uilabel','Text','Члены ряда Бесселя');
    
    % Описание режимов
    lblModeDesc = uilabel(pglBot,'Text','leadfield: быстро | farina: точнее (цилиндр) | fem: любая геометрия');
    lblModeDesc.Layout.Row = 5; lblModeDesc.Layout.Column = [1 2];
    lblModeDesc.FontAngle = 'italic';
    lblModeDesc.FontSize = 10;
    
    % Показ/скрытие параметров Farina
    update_farina_visibility();

    btnApply = uibutton(pglBot,'Text','Применить и закрыть','ButtonPushedFcn',@(s,e)on_close(),'BackgroundColor',[0.3 0.8 0.3]);
    btnApply.Layout.Row = 7; btnApply.Layout.Column = [1 2];

    ddMuscle.ValueChangedFcn = @(s,e)on_select();
    ddMode.ValueChangedFcn = @(s,e)on_mode_change();
    edDur.ValueChangedFcn = @(s,e)refresh();
    ddType.ValueChangedFcn = @(s,e)refresh();
    edFmaxPercent.ValueChangedFcn = @(s,e)update_fmax_from_percent();
    edFmax.ValueChangedFcn = @(s,e)refresh();
    edRamp.ValueChangedFcn = @(s,e)refresh();
    edHold.ValueChangedFcn = @(s,e)refresh();
    edDown.ValueChangedFcn = @(s,e)refresh();
    edStep.ValueChangedFcn = @(s,e)refresh();
    edPulseDur.ValueChangedFcn = @(s,e)refresh();
    edFreq.ValueChangedFcn = @(s,e)refresh();
    tbl.CellEditCallback = @(s,e)refresh();
    
    % Callbacks для параметров Farina
    edFarinaNk.ValueChangedFcn = @(s,e)refresh_farina_plot();
    edFarinaKmax.ValueChangedFcn = @(s,e)refresh_farina_plot();
    edFarinaBessel.ValueChangedFcn = @(s,e)refresh_farina_plot();

    setappdata(fig,'cfg_local',cfg);
    on_select();
    refresh_farina_plot();  % Первичная отрисовка графика Farina
    
    function update_farina_visibility()
        % Показываем/скрываем параметры Farina в зависимости от режима
        is_farina = strcmp(ddMode.Value, 'farina');
        vis = 'off'; if is_farina, vis = 'on'; end
        
        lblFarinaTitle.Visible = vis;
        edFarinaNk.Visible = vis;
        edFarinaKmax.Visible = vis;
        edFarinaBessel.Visible = vis;
        lblModeDesc.Visible = vis;
        if ~isempty(lblFarinaNk), set(lblFarinaNk,'Visible',vis); end
        if ~isempty(lblFarinaKmax), set(lblFarinaKmax,'Visible',vis); end
        if ~isempty(lblFarinaBessel), set(lblFarinaBessel,'Visible',vis); end
        
        if is_farina
            axFarina.Visible = 'on';
            refresh_farina_plot();
        else
            % Показываем график сравнения режимов вместо Farina
            show_solver_comparison();
        end
    end
    
    function refresh_farina_plot()
        % Визуализация модели Farina: потенциал вдоль оси z на поверхности
        cla(axFarina);
        hold(axFarina, 'on');
        
        % Параметры геометрии (из cfg)
        cfg_loc = getcfg();
        R_skin = cfg_loc.geometry.radius_outer;
        R_muscle = R_skin - cfg_loc.geometry.skin_thickness - cfg_loc.geometry.fat_thickness;
        r_source = 0.5 * R_muscle;  % Источник в середине мышцы
        r_elec = R_skin;
        
        % Проводимости
        sig_muscle_l = cfg_loc.tissues.muscle.sigma_long;
        sig_muscle_t = cfg_loc.tissues.muscle.sigma_trans;
        sig_skin = cfg_loc.tissues.skin.sigma;
        
        % Параметры Farina
        n_k = edFarinaNk.Value;
        k_max = edFarinaKmax.Value;
        
        % Анизотропный коэффициент
        alpha = sqrt(sig_muscle_l / max(sig_muscle_t, 1e-10));
        
        % Расчёт потенциала вдоль z
        z_mm = linspace(-20, 20, 100);
        z_m = z_mm * 1e-3;
        
        k = linspace(1e-3, k_max, n_k);
        
        phi = zeros(size(z_m));
        for iz = 1:length(z_m)
            delta_z = z_m(iz);
            
            % Упрощённый расчёт через интеграл
            integrand = zeros(size(k));
            for ik = 1:length(k)
                kk = k(ik);
                arg_s = kk * r_source / alpha;
                arg_e = kk * r_elec;
                
                % Масштабированные функции Бесселя
                if arg_s < 50 && arg_e < 50
                    In_s = besseli(0, arg_s, 1);
                    Kn_e = besselk(0, arg_e, 1);
                    G = In_s * Kn_e * exp(arg_s - arg_e);
                else
                    G = exp(arg_s - arg_e) / (2 * sqrt(max(arg_s * arg_e, 1e-20)));
                end
                
                if ~isfinite(G), G = 0; end
                integrand(ik) = G * cos(kk * delta_z);
            end
            
            phi(iz) = trapz(k, integrand) / (2 * pi * sig_skin);
        end
        
        % Нормализация
        phi = phi / max(abs(phi) + eps);
        
        % Рисуем
        plot(axFarina, z_mm, phi, 'b-', 'LineWidth', 2);
        
        % Добавляем сравнение с простой моделью (1/r)
        r_vec = sqrt((r_elec - r_source)^2 + z_m.^2);
        phi_simple = 1 ./ (4 * pi * sig_skin * r_vec);
        phi_simple = phi_simple / max(abs(phi_simple));
        
        plot(axFarina, z_mm, phi_simple, 'r--', 'LineWidth', 1.5);
        
        xlabel(axFarina, 'z (мм)');
        ylabel(axFarina, 'Потенциал (отн. ед.)');
        title(axFarina, sprintf('Farina vs простая модель (n_k=%d, k_{max}=%d)', n_k, k_max));
        legend(axFarina, 'Farina (цилиндр)', 'Простая (1/r)', 'Location', 'northeast');
        axFarina.XGrid = 'on';
        axFarina.YGrid = 'on';
        hold(axFarina, 'off');
    end
    
    function show_solver_comparison()
        % Показываем сравнение режимов решателя
        cla(axFarina);
        
        % Информационный текст
        text(axFarina, 0.5, 0.7, 'Режимы решателя:', 'Units', 'normalized', ...
            'HorizontalAlignment', 'center', 'FontWeight', 'bold', 'FontSize', 14);
        text(axFarina, 0.5, 0.55, 'leadfield - быстрый, дипольная аппроксимация', ...
            'Units', 'normalized', 'HorizontalAlignment', 'center', 'FontSize', 11);
        text(axFarina, 0.5, 0.45, 'farina - точный для цилиндров (Farina et al.)', ...
            'Units', 'normalized', 'HorizontalAlignment', 'center', 'FontSize', 11);
        text(axFarina, 0.5, 0.35, 'fem - точный для произвольной геометрии', ...
            'Units', 'normalized', 'HorizontalAlignment', 'center', 'FontSize', 11);
        text(axFarina, 0.5, 0.2, sprintf('Текущий режим: %s', ddMode.Value), ...
            'Units', 'normalized', 'HorizontalAlignment', 'center', ...
            'FontSize', 12, 'Color', [0 0.5 0], 'FontWeight', 'bold');
        
        title(axFarina, 'Информация о режимах решателя');
        axis(axFarina, 'off');
    end
    
    function on_mode_change()
        update_farina_visibility();
        refresh();
    end

    function lab(parent, text, r, c)
        lab = uilabel(parent,'Text',text);
        lab.Layout.Row = r; lab.Layout.Column = c;
    end
    function place(comp, r, c)
        comp.Layout.Row=r; comp.Layout.Column=c;
    end

    function cfg = getcfg(), cfg = getappdata(fig,'cfg_local'); end
    function setcfg(c), setappdata(fig,'cfg_local',c); end

    function update_fmax_from_percent()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), ddMuscle.Value), 1);
        if isempty(idx), return; end
        m = cfg.muscles{idx};
        F_max_muscle = m.sigma * m.cross_section_area * 1e4;
        edFmax.Value = F_max_muscle * edFmaxPercent.Value / 100;
        refresh();
    end

    function on_select()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), ddMuscle.Value), 1);
        if isempty(idx), idx=1; end
        m = cfg.muscles{idx};
        fp = m.force_profile;
        
        % Обновить F_max мышцы
        F_max_muscle = m.sigma * m.cross_section_area * 1e4;
        lblFmaxMuscle.Text = sprintf('F_max muscle = %.1f N', F_max_muscle);
        
        if ~isfield(fp,'custom_data') || isempty(fp.custom_data), tbl.Data = zeros(0,2);
        else, tbl.Data = fp.custom_data;
        end
        ddType.Value = fp.type;
        edFmaxPercent.Value = getf(fp,'F_max_percent',30);
        edFmax.Value = getf(fp,'F_max', F_max_muscle * edFmaxPercent.Value / 100);
        edRamp.Value = getf(fp,'ramp_time',0.25);
        edHold.Value = getf(fp,'hold_time',0.35);
        edDown.Value = getf(fp,'ramp_down_time',0.25);
        edStep.Value = getf(fp,'step_time',0.2);
        edPulseDur.Value = getf(fp,'pulse_duration',0.1);
        edFreq.Value = getf(fp,'frequency',0.5);
        ddMode.Value = cfg.simulation.solver_mode;
        edDur.Value = cfg.simulation.duration;
        refresh();
    end

    function gen_custom()
        cfg = getcfg();
        idx = find(strcmp(muscle_names(cfg), ddMuscle.Value), 1);
        fp = read_fp();
        T = cfg.simulation.duration;
        dt = 0.05; % coarse points; user can edit
        tt = (0:dt:T).';
        F = zeros(size(tt));
        for i=1:numel(tt)
            F(i)=core_force_profile_eval(tt(i), fp);
        end
        tbl.Data = [tt,F];
        fp.type='custom';
        fp.custom_data = tbl.Data;
        cfg.muscles{idx}.force_profile = fp;
        setcfg(cfg);
        refresh();
    end


function add_row()
    D = tbl.Data;
    if isempty(D), D = [0 0]; else, D(end+1,:) = D(end,:); D(end,1) = D(end,1) + 0.1; end
    tbl.Data = D;
    refresh();
end

function del_row()
    D = tbl.Data;
    if isempty(D), return; end
    D(end,:) = [];
    tbl.Data = D;
    refresh();
end

function sort_points()
    D = tbl.Data;
    if isempty(D), return; end
    [~,ix] = sort(D(:,1));
    tbl.Data = D(ix,:);
    refresh();
end

    function fp = read_fp()
        fp = struct();
        fp.type = ddType.Value;
        fp.F_max = edFmax.Value;
        fp.ramp_time = edRamp.Value;
        fp.hold_time = edHold.Value;
        fp.ramp_down_time = edDown.Value;
        fp.step_time = edStep.Value;
        fp.pulse_duration = edPulseDur.Value;
        fp.frequency = edFreq.Value;
        fp.custom_data = tbl.Data;
    end

    function refresh()
        cfg = getcfg();
        cfg.simulation.solver_mode = ddMode.Value;
        cfg.simulation.duration = edDur.Value;

        idx = find(strcmp(muscle_names(cfg), ddMuscle.Value), 1);
        fp = read_fp();
        cfg.muscles{idx}.force_profile = fp;
        setcfg(cfg);

        tt = linspace(0,cfg.simulation.duration,1000);
        % Avoid heavy eval errors for insufficient custom points
        if strcmp(fp.type,'custom') && (~isfield(fp,'custom_data') || size(fp.custom_data,1) < 2)
            if isfield(fp,'custom_data') && size(fp.custom_data,1)==1
                F = fp.custom_data(1,2) * ones(size(tt));
            else
                F = zeros(size(tt));
            end
        else
            F = arrayfun(@(x)core_force_profile_eval(x,fp), tt);
        end
        cla(ax); plot(ax,tt,F);
        xlim(ax,[0 cfg.simulation.duration]);
        ylim(ax,[min(0,min(F)) max(1e-6,max(F)*1.05)]);
        title(ax, sprintf('Muscle: %s', cfg.muscles{idx}.name));
    end

    function on_close()
        cfg = getcfg();
        
        % Сохраняем параметры Farina
        if ~isfield(cfg, 'solver')
            cfg.solver = struct();
        end
        if ~isfield(cfg.solver, 'farina')
            cfg.solver.farina = struct();
        end
        cfg.solver.farina.n_k_points = edFarinaNk.Value;
        cfg.solver.farina.k_max = edFarinaKmax.Value;
        cfg.solver.farina.n_bessel_terms = edFarinaBessel.Value;
        
        cfg = validate_cfg_for_core(cfg);
        set_cfg_cb(cfg);
        delete(fig);
    end
end


function v = get_mfield(m, field, def)
    if isfield(m,field), v = m.(field); else, v = def; end
end

function v = getf(S, field, def)
    if isfield(S,field), v = S.(field); else, v = def; end
end

function sensors_editor(cfg, set_cfg_cb)
    fig = uifigure('Name','Окно 3: Датчики / Электроды / Помехи','Position',[100 100 1340 760],...
        'AutoResizeChildren','on','Resize','on');

    gl = uigridlayout(fig,[1 3]);
    gl.ColumnWidth = {580,'1x','1x'};

    % === Левая колонка: вкладки ===
    leftTabs = uitabgroup(gl);

    % ====== Вкладка 1: Электродный массив ======
    tab1 = uitab(leftTabs,'Title','Электродный массив');
    pgl = uigridlayout(tab1,[22 2]);
    pgl.ColumnWidth = {280,'1x'};
    pgl.RowHeight = repmat({26},1,21);

    ax2 = uiaxes(gl); ax2.XGrid='on'; ax2.YGrid='on';
    axCS = uiaxes(gl); axCS.DataAspectRatio=[1 1 1]; axCS.XGrid='on'; axCS.YGrid='on';
    title(axCS,'Сечение (размещение электродов)');
    xlabel(axCS,'X (м)'); ylabel(axCS,'Y (м)');
    title(ax2,'Развёртка кожи (дуга vs z)');
    xlabel(ax2,'z (м)'); ylabel(ax2,'дуга s (м)');

    ddArray = uidropdown(pgl,'Items',array_names(cfg),'Value',cfg.electrode_arrays{1}.name);
    lab(pgl,'Электродный массив',1,1); place(ddArray,1,2);

    btnAdd = uibutton(pgl,'Text','+ Массив','ButtonPushedFcn',@(s,e)add_array());
    btnAdd.Layout.Row=2; btnAdd.Layout.Column=1;
    btnDel = uibutton(pgl,'Text','- Массив','ButtonPushedFcn',@(s,e)del_array());
    btnDel.Layout.Row=2; btnDel.Layout.Column=2;

    edName = uieditfield(pgl,'text','Value',cfg.electrode_arrays{1}.name); lab(pgl,'Название',3,1); place(edName,3,2);
    edNE = uieditfield(pgl,'numeric','Value',3,'RoundFractionalValues','on');
    edNE.Editable = 'off';
    lab(pgl,'Число электродов (фикс.)',4,1); place(edNE,4,2);

    edAngle = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.angle,'Limits',[-180 180]);
    lab(pgl,'Угол положения (град)',5,1); place(edAngle,5,2);
    edZ = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.position_z,'Limits',[0 10]);
    lab(pgl,'Центр по z (м)',6,1); place(edZ,6,2);
    edSpacing = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.spacing,'Limits',[0 0.2]);
    lab(pgl,'Межэлектродн. расстояние (м)',7,1); place(edSpacing,7,2);
    edW = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.size(1),'Limits',[1e-4 0.05]);
    lab(pgl,'Ширина электрода (м)',8,1); place(edW,8,2);
    edH = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.size(2),'Limits',[1e-4 0.05]);
    lab(pgl,'Высота электрода (м)',9,1); place(edH,9,2);
    edRot = uieditfield(pgl,'numeric','Value',get_afield(cfg.electrode_arrays{1},'rotation_deg',0),'Limits',[-180 180]);
    lab(pgl,'Поворот датчика (град)',10,1); place(edRot,10,2);
    edRs = uieditfield(pgl,'numeric','Value',getf(cfg.electrode_arrays{1}.contact,'Rs',200),'Limits',[0 1e8]);
    lab(pgl,'Послед. сопр. Rs (Ом)',11,1); place(edRs,11,2);
    edRc = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.contact.Rc,'Limits',[1 1e9]);
    lab(pgl,'Сопротивление контакта Rc (Ом)',12,1); place(edRc,12,2);
    edCc = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.contact.Cc,'Limits',[1e-12 1]);
    lab(pgl,'Ёмкость контакта Cc (Ф)',13,1); place(edCc,13,2);
    edG = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.amplifier.gain,'Limits',[1 1e6]);
    lab(pgl,'Коэффициент усиления',14,1); place(edG,14,2);
    edCMRR = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.amplifier.cmrr_db,'Limits',[40 140]);
    lab(pgl,'CMRR (дБ)',15,1); place(edCMRR,15,2);
    edZin = uieditfield(pgl,'numeric','Value',get_afield(cfg.electrode_arrays{1}.amplifier,'input_impedance',200e6)/1e6,'Limits',[1 1e5]);
    lab(pgl,'Вх. сопр. Z_in (МОм)',16,1); place(edZin,16,2);
    edHP = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.amplifier.highpass_cutoff,'Limits',[0.1 1000]);
    lab(pgl,'ФВЧ срез (Гц)',17,1); place(edHP,17,2);
    edLP = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.amplifier.lowpass_cutoff,'Limits',[10 5000]);
    lab(pgl,'ФНЧ срез (Гц)',18,1); place(edLP,18,2);
    edNotch = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.amplifier.notch_freq,'Limits',[0 1000]);
    lab(pgl,'Режекторный фильтр (Гц)',19,1); place(edNotch,19,2);
    edNBW = uieditfield(pgl,'numeric','Value',cfg.electrode_arrays{1}.amplifier.notch_bw,'Limits',[0.1 200]);
    lab(pgl,'Полоса режектора (Гц)',20,1); place(edNBW,20,2);

    % Пустая строка
    uilabel(pgl,'Text',''); % spacer

    btnApply = uibutton(pgl,'Text','Применить и закрыть','ButtonPushedFcn',@(s,e)on_close(),'BackgroundColor',[0.3 0.8 0.3]);
    btnApply.Layout.Row=22; btnApply.Layout.Column=[1 2];

    % ====== Вкладка 2: Помехи / Земля / Дисбаланс ======
    tab2 = uitab(leftTabs,'Title','Помехи / Земля');
    glTab2 = uigridlayout(tab2,[1 1]);
    glTab2.Padding = [0 0 0 0];
    innerTabs = uitabgroup(glTab2);

    % --- Под-вкладка 2a: Сетевая помеха ---
    tabMains = uitab(innerTabs,'Title','Сетевая помеха');
    pglM = uigridlayout(tabMains,[12 2]);
    pglM.ColumnWidth = {300,'1x'};
    pglM.RowHeight = repmat({26},1,12);

    if ~isfield(cfg,'interference'), cfg.interference = struct(); end
    if ~isfield(cfg.interference,'mains'), cfg.interference.mains = struct(); end
    mc = cfg.interference.mains;

    lab(pglM,'Включить сетевую помеху',1,1);
    cbMainsEnabled = uicheckbox(pglM,'Value',getf(mc,'enabled',false),'Text','');
    place(cbMainsEnabled,1,2);
    lab(pglM,'Частота сети (Гц)',2,1);
    edMainsFreq = uieditfield(pglM,'numeric','Value',getf(mc,'frequency',50),'Limits',[40 70]);
    place(edMainsFreq,2,2);
    lab(pglM,'Амплитуда синфазной помехи (мВ)',3,1);
    edMainsAmp = uieditfield(pglM,'numeric','Value',getf(mc,'amplitude_Vp',1e-3)*1000,'Limits',[0 500]);
    place(edMainsAmp,3,2);
    lab(pglM,'Число нечётных гармоник',4,1);
    edMainsHarm = uieditfield(pglM,'numeric','Value',getf(mc,'n_harmonics',3),'Limits',[0 10],'RoundFractionalValues','on');
    place(edMainsHarm,4,2);
    lab(pglM,'Затухание гармоник (отн.)',5,1);
    edMainsHarmDecay = uieditfield(pglM,'numeric','Value',getf(mc,'harmonic_decay',0.3),'Limits',[0 1]);
    place(edMainsHarmDecay,5,2);
    lab(pglM,'DC смещение (мВ)',6,1);
    edMainsDC = uieditfield(pglM,'numeric','Value',getf(mc,'dc_offset_V',0)*1000,'Limits',[-500 500]);
    place(edMainsDC,6,2);
    lab(pglM,'Разброс DC между эл-дами (мВ)',7,1);
    edMainsDCspread = uieditfield(pglM,'numeric','Value',getf(mc,'dc_offset_spread_V',0.005)*1000,'Limits',[0 50]);
    place(edMainsDCspread,7,2);
    lab(pglM,'Фазовый шум (°)',8,1);
    edMainsPhase = uieditfield(pglM,'numeric','Value',getf(mc,'phase_noise_deg',5),'Limits',[0 30]);
    place(edMainsPhase,8,2);
    lab(pglM,'Вариация амплитуды (отн.)',9,1);
    edMainsAmpNoise = uieditfield(pglM,'numeric','Value',getf(mc,'amplitude_noise',0.05),'Limits',[0 0.5]);
    place(edMainsAmpNoise,9,2);

    % --- Под-вкладка 2b: Дисбаланс контакта ---
    tabImb = uitab(innerTabs,'Title','Дисбаланс контакта');
    pglI = uigridlayout(tabImb,[20 2]);
    pglI.ColumnWidth = {300,'1x'};
    pglI.RowHeight = repmat({26},1,20);

    lab(pglI,'Массив для настройки',1,1);
    ddImbArray = uidropdown(pglI,'Items',array_names(cfg),'Value',cfg.electrode_arrays{1}.name);
    place(ddImbArray,1,2);
    lab(pglI,'Включить дисбаланс',2,1);
    cbImbEnabled = uicheckbox(pglI,'Value',false,'Text','');
    place(cbImbEnabled,2,2);

    lab(pglI,'Пресет',3,1);
    ddImbPreset = uidropdown(pglI,'Items',{'Ручной','Лёгкий','Сильный','Отвалился E1'},'Value','Ручной');
    place(ddImbPreset,3,2);

    lblSepRs = uilabel(pglI,'Text','── Rs (Ом) по электродам ──','FontWeight','bold');
    lblSepRs.Layout.Row=4; lblSepRs.Layout.Column=[1 2];
    lab(pglI,'E1 (IN+) Rs, Ом',5,1);
    edImbRs1 = uieditfield(pglI,'numeric','Value',200,'Limits',[0 1e8],'ValueDisplayFormat','%.0f'); place(edImbRs1,5,2);
    lab(pglI,'E_ref (центр.) Rs, Ом',6,1);
    edImbRsRef = uieditfield(pglI,'numeric','Value',200,'Limits',[0 1e8],'ValueDisplayFormat','%.0f'); place(edImbRsRef,6,2);
    lab(pglI,'E3 (IN-) Rs, Ом',7,1);
    edImbRs3 = uieditfield(pglI,'numeric','Value',200,'Limits',[0 1e8],'ValueDisplayFormat','%.0f'); place(edImbRs3,7,2);

    lblSepRc = uilabel(pglI,'Text','── Rc (кОм) по электродам ──','FontWeight','bold');
    lblSepRc.Layout.Row=8; lblSepRc.Layout.Column=[1 2];
    lab(pglI,'E1 (IN+) Rc, кОм',9,1);
    edImbRc1 = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e8],'ValueDisplayFormat','%.1f'); place(edImbRc1,9,2);
    lab(pglI,'E_ref (центр.) Rc, кОм',10,1);
    edImbRcRef = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e8],'ValueDisplayFormat','%.1f'); place(edImbRcRef,10,2);
    lab(pglI,'E3 (IN-) Rc, кОм',11,1);
    edImbRc3 = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e8],'ValueDisplayFormat','%.1f'); place(edImbRc3,11,2);
    lab(pglI,'Земля Rc, кОм',12,1);
    edImbRcGnd = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e8],'ValueDisplayFormat','%.1f'); place(edImbRcGnd,12,2);

    lblSepCc = uilabel(pglI,'Text','── Cc (нФ) по электродам ──','FontWeight','bold');
    lblSepCc.Layout.Row=13; lblSepCc.Layout.Column=[1 2];
    lab(pglI,'E1 (IN+) Cc, нФ',14,1);
    edImbCc1 = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e6],'ValueDisplayFormat','%.1f'); place(edImbCc1,14,2);
    lab(pglI,'E_ref (центр.) Cc, нФ',15,1);
    edImbCcRef = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e6],'ValueDisplayFormat','%.1f'); place(edImbCcRef,15,2);
    lab(pglI,'E3 (IN-) Cc, нФ',16,1);
    edImbCc3 = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e6],'ValueDisplayFormat','%.1f'); place(edImbCc3,16,2);
    lab(pglI,'Земля Cc, нФ',17,1);
    edImbCcGnd = uieditfield(pglI,'numeric','Value',100,'Limits',[0.001 1e6],'ValueDisplayFormat','%.1f'); place(edImbCcGnd,17,2);

    % Info label
    lblImbInfo = uilabel(pglI,'Text','','FontColor',[0.3 0.3 0.7]);
    lblImbInfo.Layout.Row=[18 20]; lblImbInfo.Layout.Column=[1 2];
    try lblImbInfo.WordWrap = 'on'; catch, end

    setappdata(fig,'cfg_local',cfg);  % must be before load_*_ui() calls

    % --- Commit + Switch для дисбаланса ---
    ddImbArray.ValueChangedFcn = @(s,e) cb_switch_imb_array(e);
    function cb_switch_imb_array(~)
        commit_imbalance();    % сохранить текущие значения
        load_imbalance_ui();   % загрузить новые
    end

    % Пресет
    ddImbPreset.ValueChangedFcn = @(s,e) apply_imb_preset();
    function apply_imb_preset()
        c = getcfg();
        aidx = getappdata(fig, 'last_imb_idx');
        if isempty(aidx), return; end
        a = c.electrode_arrays{aidx};
        Rc_base = a.contact.Rc / 1e3;  % кОм
        Cc_base = a.contact.Cc / 1e-9; % нФ
        pv = ddImbPreset.Value;
        switch pv
            case 'Лёгкий'
                edImbRc1.Value = Rc_base*3;   edImbCc1.Value = Cc_base*0.7;
                edImbRc3.Value = Rc_base;     edImbCc3.Value = Cc_base;
            case 'Сильный'
                edImbRc1.Value = Rc_base*50;  edImbCc1.Value = Cc_base*0.1;
                edImbRc3.Value = Rc_base;     edImbCc3.Value = Cc_base;
            case 'Отвалился E1'
                edImbRc1.Value = 100000;      edImbCc1.Value = 1;  % 100МОм, 1нФ
                edImbRc3.Value = Rc_base;     edImbCc3.Value = Cc_base;
            otherwise  % Ручной
                return;
        end
        cbImbEnabled.Value = true;
        commit_imbalance();
        update_imb_info();
    end

    function commit_imbalance()
        c = getcfg();
        aidx = getappdata(fig, 'last_imb_idx');
        if isempty(aidx) || aidx < 1 || aidx > numel(c.electrode_arrays), return; end
        a = c.electrode_arrays{aidx};
        if ~isfield(a,'contact_imbalance'), a.contact_imbalance = struct(); end
        a.contact_imbalance.enabled = cbImbEnabled.Value;
        % Абсолютные значения (кОм, нФ) → факторы относительно базового Rc/Cc
        Rc_base = a.contact.Rc;  % Ом
        Cc_base = a.contact.Cc;  % Ф
        a.contact_imbalance.Rc_factors = [edImbRc1.Value*1e3, edImbRcRef.Value*1e3, edImbRc3.Value*1e3] / max(Rc_base, eps);
        a.contact_imbalance.Cc_factors = [edImbCc1.Value*1e-9, edImbCcRef.Value*1e-9, edImbCc3.Value*1e-9] / max(Cc_base, eps);
        Rs_base = max(getf(a.contact, 'Rs', 200), eps);
        a.contact_imbalance.Rs_factors = [edImbRs1.Value, edImbRsRef.Value, edImbRs3.Value] / Rs_base;
        a.contact_imbalance.Rc_ground_factor = edImbRcGnd.Value*1e3 / max(Rc_base, eps);
        a.contact_imbalance.Cc_ground_factor = edImbCcGnd.Value*1e-9 / max(Cc_base, eps);
        c.electrode_arrays{aidx} = a;
        setcfg(c);
        update_imb_info();
    end

    function load_imbalance_ui()
        c = getcfg();
        aidx = find(strcmp(array_names(c), ddImbArray.Value), 1);
        if isempty(aidx), return; end
        setappdata(fig, 'last_imb_idx', aidx);
        a = c.electrode_arrays{aidx};
        imb = getf(a,'contact_imbalance',struct());
        cbImbEnabled.Value = getf(imb,'enabled',false);
        % Факторы → абсолютные значения (кОм, нФ)
        Rc_base = a.contact.Rc;  % Ом
        Cc_base = a.contact.Cc;  % Ф
        rc = getf(imb,'Rc_factors',[1 1 1]);
        cc = getf(imb,'Cc_factors',[1 1 1]);
        edImbRc1.Value = Rc_base*rc(1)/1e3;
        edImbRcRef.Value = Rc_base*rc(2)/1e3;
        edImbRc3.Value = Rc_base*rc(3)/1e3;
        edImbCc1.Value = Cc_base*cc(1)/1e-9;
        edImbCcRef.Value = Cc_base*cc(2)/1e-9;
        edImbCc3.Value = Cc_base*cc(3)/1e-9;
        edImbRcGnd.Value = Rc_base*getf(imb,'Rc_ground_factor',1.0)/1e3;
        edImbCcGnd.Value = Cc_base*getf(imb,'Cc_ground_factor',1.0)/1e-9;
        % Rs
        Rs_base = getf(a.contact, 'Rs', 200);
        rs = getf(imb, 'Rs_factors', [1 1 1]);
        edImbRs1.Value = Rs_base*rs(1);
        edImbRsRef.Value = Rs_base*rs(min(2,end));
        edImbRs3.Value = Rs_base*rs(min(3,end));
        ddImbPreset.Value = 'Ручной';
        update_imb_info();
    end

    function update_imb_info()
        c = getcfg();
        aidx = getappdata(fig, 'last_imb_idx');
        if isempty(aidx), return; end
        a = c.electrode_arrays{aidx};
        Z_in = a.amplifier.input_impedance;
        Rs1 = edImbRs1.Value; Rs3 = edImbRs3.Value;
        Rc1 = edImbRc1.Value * 1e3; Rc3 = edImbRc3.Value * 1e3;
        H1_dc = Z_in / (Rs1 + Rc1 + Z_in);
        H3_dc = Z_in / (Rs3 + Rc3 + Z_in);
        H1_hf = Z_in / (Rs1 + Z_in);
        H3_hf = Z_in / (Rs3 + Z_in);
        txt = sprintf(['Z_in=%.0fМОм\nDC: H1=%.4f H3=%.4f ΔH=%.4f\n' ...
            'ВЧ: H1=%.4f H3=%.4f ΔH=%.4f (%.1f%%)'], ...
            Z_in/1e6, H1_dc, H3_dc, abs(H1_dc-H3_dc), ...
            H1_hf, H3_hf, abs(H1_hf-H3_hf), abs(H1_hf-H3_hf)*100);
        lblImbInfo.Text = txt;
    end

    % ValueChangedFcn для контролов дисбаланса (live-save)
    imb_ctrls = {cbImbEnabled, edImbRs1, edImbRsRef, edImbRs3, ...
                 edImbRc1, edImbRcRef, edImbRc3, edImbRcGnd, ...
                 edImbCc1, edImbCcRef, edImbCc3, edImbCcGnd};
    for ic=1:numel(imb_ctrls)
        imb_ctrls{ic}.ValueChangedFcn = @(s,e) commit_imbalance();
    end

    load_imbalance_ui();

    % --- Под-вкладка 2c: Позиция Ref / Земля ---
    tabRef = uitab(innerTabs,'Title','Ref / Земля');
    pglR = uigridlayout(tabRef,[14 2]);
    pglR.ColumnWidth = {300,'1x'};
    pglR.RowHeight = repmat({26},1,14);

    lab(pglR,'Массив для настройки',1,1);
    ddRefArray = uidropdown(pglR,'Items',array_names(cfg),'Value',cfg.electrode_arrays{1}.name);
    place(ddRefArray,1,2);

    lblRefSep = uilabel(pglR,'Text','── Reference электрод ──','FontWeight','bold');
    lblRefSep.Layout.Row=2; lblRefSep.Layout.Column=[1 2];
    lab(pglR,'Произвольная позиция ref',3,1);
    cbRefCustom = uicheckbox(pglR,'Value',false,'Text',''); place(cbRefCustom,3,2);
    lab(pglR,'Ref: угол (°)',4,1);
    edRefAngle = uieditfield(pglR,'numeric','Value',0,'Limits',[-180 180]); place(edRefAngle,4,2);
    lab(pglR,'Ref: z (м)',5,1);
    edRefZ = uieditfield(pglR,'numeric','Value',0.12,'Limits',[0 10]); place(edRefZ,5,2);

    lblGndSep = uilabel(pglR,'Text','── Электрод земли (Ground / DRL) ──','FontWeight','bold');
    lblGndSep.Layout.Row=6; lblGndSep.Layout.Column=[1 2];
    lab(pglR,'Включить отдельную землю',7,1);
    cbGndEnabled = uicheckbox(pglR,'Value',false,'Text',''); place(cbGndEnabled,7,2);
    lab(pglR,'Земля: угол (°)',8,1);
    edGndAngle = uieditfield(pglR,'numeric','Value',90,'Limits',[-180 180]); place(edGndAngle,8,2);
    lab(pglR,'Земля: z (м)',9,1);
    edGndZ = uieditfield(pglR,'numeric','Value',0.06,'Limits',[0 10]); place(edGndZ,9,2);
    lab(pglR,'Земля: Rc (Ом)',10,1);
    edGndRc = uieditfield(pglR,'numeric','Value',100e3,'Limits',[1 1e9]); place(edGndRc,10,2);
    lab(pglR,'Земля: Cc (Ф)',11,1);
    edGndCc = uieditfield(pglR,'numeric','Value',100e-9,'Limits',[1e-12 1]); place(edGndCc,11,2);

    % --- Commit + Switch для ref/ground ---
    ddRefArray.ValueChangedFcn = @(s,e) cb_switch_ref_array(e);
    function cb_switch_ref_array(~)
        commit_refgnd();
        load_refgnd_ui();
    end

    function commit_refgnd()
        c = getcfg();
        aidx = getappdata(fig, 'last_ref_idx');
        if isempty(aidx) || aidx < 1 || aidx > numel(c.electrode_arrays), return; end
        a = c.electrode_arrays{aidx};
        if ~isfield(a,'ref_position'), a.ref_position = struct(); end
        a.ref_position.custom_enabled = cbRefCustom.Value;
        a.ref_position.angle = edRefAngle.Value;
        a.ref_position.position_z = edRefZ.Value;
        if ~isfield(a,'ground_electrode'), a.ground_electrode = struct(); end
        a.ground_electrode.enabled = cbGndEnabled.Value;
        a.ground_electrode.angle = edGndAngle.Value;
        a.ground_electrode.position_z = edGndZ.Value;
        a.ground_electrode.Rc = edGndRc.Value;
        a.ground_electrode.Cc = edGndCc.Value;
        c.electrode_arrays{aidx} = a;
        setcfg(c);
    end

    function load_refgnd_ui()
        c = getcfg();
        aidx = find(strcmp(array_names(c), ddRefArray.Value), 1);
        if isempty(aidx), return; end
        setappdata(fig, 'last_ref_idx', aidx);
        a = c.electrode_arrays{aidx};
        rp = getf(a,'ref_position',struct());
        cbRefCustom.Value = getf(rp,'custom_enabled',false);
        edRefAngle.Value = getf(rp,'angle',a.angle);
        edRefZ.Value = getf(rp,'position_z',a.position_z);
        ge = getf(a,'ground_electrode',struct());
        cbGndEnabled.Value = getf(ge,'enabled',false);
        edGndAngle.Value = getf(ge,'angle',a.angle+90);
        edGndZ.Value = getf(ge,'position_z',0.06);
        edGndRc.Value = getf(ge,'Rc',100e3);
        edGndCc.Value = getf(ge,'Cc',100e-9);
    end

    % ValueChangedFcn для ref/ground контролов (live-save + refresh_plot)
    ref_ctrls = {cbRefCustom, edRefAngle, edRefZ, cbGndEnabled, edGndAngle, edGndZ, edGndRc, edGndCc};
    for ic=1:numel(ref_ctrls)
        ref_ctrls{ic}.ValueChangedFcn = @(s,e) on_refgnd_changed();
    end
    function on_refgnd_changed()
        commit_refgnd();
        refresh_plot();
    end

    load_refgnd_ui();

    % --- Под-вкладка 2d: Объединение земель ---
    tabGM = uitab(innerTabs,'Title','Объединение земель');
    pglG = uigridlayout(tabGM,[8 2]);
    pglG.ColumnWidth = {300,'1x'};
    pglG.RowHeight = repmat({26},1,8);

    if ~isfield(cfg.interference,'ground_merge'), cfg.interference.ground_merge = struct(); end
    gm_cfg = cfg.interference.ground_merge;

    lab(pglG,'Включить объединение земель',1,1);
    cbGMEnabled = uicheckbox(pglG,'Value',getf(gm_cfg,'enabled',false),'Text','');
    place(cbGMEnabled,1,2);
    lab(pglG,'Доступные массивы:',2,1);
    lblGMArrays = uilabel(pglG,'Text',strjoin(array_names(cfg),', '),'FontColor',[0.2 0.2 0.6]);
    place(lblGMArrays,2,2);

    gm_groups = getf(gm_cfg,'groups',{});
    grp1_str=''; grp2_str=''; grp3_str='';
    if numel(gm_groups)>=1, grp1_str = mat2str(gm_groups{1}); end
    if numel(gm_groups)>=2, grp2_str = mat2str(gm_groups{2}); end
    if numel(gm_groups)>=3, grp3_str = mat2str(gm_groups{3}); end

    lab(pglG,'Группа 1 (напр. [1 2])',3,1);
    edGMGroup1 = uieditfield(pglG,'text','Value',grp1_str); place(edGMGroup1,3,2);
    lab(pglG,'Группа 2',4,1);
    edGMGroup2 = uieditfield(pglG,'text','Value',grp2_str); place(edGMGroup2,4,2);
    lab(pglG,'Группа 3',5,1);
    edGMGroup3 = uieditfield(pglG,'text','Value',grp3_str); place(edGMGroup3,5,2);

    % ====== Callbacks и логика ======
    ddArray.ValueChangedFcn = @(s,e)on_select();
    edName.ValueChangedFcn  = @(s,e)write_array();
    edNE.ValueChangedFcn    = @(s,e)write_array();
    edAngle.ValueChangedFcn = @(s,e)write_array();
    edZ.ValueChangedFcn     = @(s,e)write_array();
    edSpacing.ValueChangedFcn = @(s,e)write_array();
    edW.ValueChangedFcn     = @(s,e)write_array();
    edH.ValueChangedFcn     = @(s,e)write_array();
    edRot.ValueChangedFcn   = @(s,e)write_array();
    edRc.ValueChangedFcn    = @(s,e)write_array();
    edCc.ValueChangedFcn    = @(s,e)write_array();
    edG.ValueChangedFcn     = @(s,e)write_array();
    edCMRR.ValueChangedFcn  = @(s,e)write_array();
    edZin.ValueChangedFcn   = @(s,e)write_array();
    edHP.ValueChangedFcn    = @(s,e)write_array();
    edLP.ValueChangedFcn    = @(s,e)write_array();
    edNotch.ValueChangedFcn = @(s,e)write_array();
    edNBW.ValueChangedFcn   = @(s,e)write_array();

    on_select();

    function lab(parent, text, r, c)
        lbl = uilabel(parent,'Text',text);
        lbl.Layout.Row = r; lbl.Layout.Column = c;
    end
    function place(comp, r, c)
        comp.Layout.Row=r; comp.Layout.Column=c;
    end

    function cfg = getcfg(), cfg = getappdata(fig,'cfg_local'); end
    function setcfg(c), setappdata(fig,'cfg_local',c); end

    function on_select()
        cfg = getcfg();
        idx = find(strcmp(array_names(cfg), ddArray.Value), 1);
        if isempty(idx), idx=1; end
        a = cfg.electrode_arrays{idx};
        edName.Value = a.name;
        edNE.Value = a.n_electrodes;
        edAngle.Value = a.angle;
        edZ.Value = a.position_z;
        edSpacing.Value = a.spacing;
        edW.Value = a.size(1);
        edH.Value = a.size(2);
        edRot.Value = get_afield(a,'rotation_deg',0);
        edRs.Value = getf(a.contact,'Rs',200);
        edRc.Value = a.contact.Rc;
        edCc.Value = a.contact.Cc;
        edG.Value = a.amplifier.gain;
        edCMRR.Value = a.amplifier.cmrr_db;
        edZin.Value = get_afield(a.amplifier,'input_impedance',200e6) / 1e6;
        edHP.Value = a.amplifier.highpass_cutoff;
        edLP.Value = a.amplifier.lowpass_cutoff;
        edNotch.Value = a.amplifier.notch_freq;
        edNBW.Value = a.amplifier.notch_bw;
        refresh_plot();
    end

    function add_array()
        cfg = getcfg();
        na = numel(cfg.electrode_arrays)+1;
        cfg.electrode_arrays{na} = default_electrode_array(sprintf('Array_%d',na), 30*(na-1));
        ddArray.Items = array_names(cfg);
        ddArray.Value = cfg.electrode_arrays{na}.name;
        % Обновляем dropdowns помех
        ddImbArray.Items = array_names(cfg);
        ddRefArray.Items = array_names(cfg);
        lblGMArrays.Text = strjoin(array_names(cfg),', ');
        setcfg(cfg);
        on_select();
    end

    function del_array()
        cfg = getcfg();
        if numel(cfg.electrode_arrays) <= 1
            uialert(fig,'Нельзя удалить последний массив.','Info'); return;
        end
        idx = find(strcmp(array_names(cfg), ddArray.Value), 1);
        cfg.electrode_arrays(idx) = [];
        ddArray.Items = array_names(cfg);
        ddArray.Value = cfg.electrode_arrays{max(1,min(idx,numel(cfg.electrode_arrays)))}.name;
        ddImbArray.Items = array_names(cfg);
        ddImbArray.Value = ddArray.Value;
        ddRefArray.Items = array_names(cfg);
        ddRefArray.Value = ddArray.Value;
        lblGMArrays.Text = strjoin(array_names(cfg),', ');
        setcfg(cfg);
        on_select();
    end

    function write_array()
        cfg = getcfg();
        idx = find(strcmp(array_names(cfg), ddArray.Value), 1);
        a = cfg.electrode_arrays{idx};

        a.name = edName.Value;
        a.n_electrodes = 3;
        a.angle = edAngle.Value;
        a.position_z = edZ.Value;
        a.spacing = edSpacing.Value;
        a.size = [edW.Value, edH.Value];
        a.rotation_deg = edRot.Value;
        a.contact.Rs = edRs.Value;
        a.contact.Rc = edRc.Value;
        a.contact.Cc = edCc.Value;
        a.amplifier.gain = edG.Value;
        a.amplifier.cmrr_db = edCMRR.Value;
        a.amplifier.input_impedance = edZin.Value * 1e6;  % МОм → Ом
        a.amplifier.highpass_cutoff = edHP.Value;
        a.amplifier.lowpass_cutoff = edLP.Value;
        a.amplifier.notch_freq = edNotch.Value;
        a.amplifier.notch_bw = edNBW.Value;

        cfg.electrode_arrays{idx} = a;
        ddArray.Items = array_names(cfg);
        ddArray.Value = a.name;
        % Sync interference dropdowns
        ddImbArray.Items = array_names(cfg);
        ddRefArray.Items = array_names(cfg);
        lblGMArrays.Text = strjoin(array_names(cfg),', ');

        setcfg(cfg);
        refresh_plot();
    end

    function refresh_plot()
    cfg = getcfg();
    Rskin = cfg.geometry.radius_outer;
    L = cfg.geometry.length;

    % ===== Развёртка кожи (unwrap): z vs дуга s =====
    cla(ax2); hold(ax2,'on');
    for k=1:numel(cfg.electrode_arrays)
        a = cfg.electrode_arrays{k};
        n = 3;
        z0 = a.position_z;
        rot = getf(a,'rotation_deg',0) * pi/180;
        offsets = ((1:n) - (n+1)/2) * a.spacing;
        zz = z0 + offsets * cos(rot);
        ang_arr = a.angle + (offsets * sin(rot) / Rskin) * (180/pi);

        % Если custom ref — сдвигаем E2 (центральный) в заданную позицию
        rp = getf(a,'ref_position',struct());
        if getf(rp,'custom_enabled',false)
            zz(2) = getf(rp,'position_z',z0);
            ang_arr(2) = getf(rp,'angle',a.angle);
        end

        draw_electrode_rects(ax2, cfg, a, zz, ang_arr);
        text(ax2, zz(1), ang_arr(1)*pi/180*Rskin, sprintf(' %s', a.name), 'FontSize', 8);

        % Ground электрод (если включён)
        ge = getf(a,'ground_electrode',struct());
        if getf(ge,'enabled',false)
            gnd_z = getf(ge,'position_z',0.06);
            gnd_s = getf(ge,'angle',a.angle+90)*pi/180*Rskin;
            plot(ax2, gnd_z, gnd_s, 'gv', 'MarkerSize',8, 'MarkerFaceColor',[0 0.7 0]);
            text(ax2, gnd_z, gnd_s, ' GND', 'FontSize',7, 'Color',[0 0.5 0]);
        end
    end
    xlim(ax2,[0 max(L, 0.01)]);
    ylim(ax2,[-pi*Rskin pi*Rskin]);
    hold(ax2,'off');

    % ===== Поперечное сечение =====
    cla(axCS); hold(axCS,'on');
    axCS.DataAspectRatio = [1 1 1];
    Rfat  = Rskin - cfg.geometry.skin_thickness;
    Rfas  = Rfat  - cfg.geometry.fat_thickness;
    Rmus  = Rfas  - cfg.geometry.fascia_thickness;
    fill_circle(axCS,0,0,Rskin,[0.9 0.9 0.9],0.10);
    fill_circle(axCS,0,0,Rfat,[0.95 0.88 0.80],0.18);
    fill_circle(axCS,0,0,Rfas,[0.85 0.92 0.85],0.12);
    fill_circle(axCS,0,0,Rmus,[0.85 0.88 0.95],0.10);
    draw_circle(axCS,0,0,Rskin,'k-');
    for b=1:size(cfg.geometry.bones.positions,1)
        x = cfg.geometry.bones.positions(b,1);
        y = cfg.geometry.bones.positions(b,2);
        r = cfg.geometry.bones.radii(b);
        draw_circle(axCS,x,y,r,'k-');
    end
    for kk=1:numel(cfg.muscles)
        m = cfg.muscles{kk};
        ang_m = m.position_angle*pi/180;
        base_cx = m.depth*cos(ang_m);
        base_cy = m.depth*sin(ang_m);
        if isfield(m,'polygon') && ~isempty(m.polygon) && size(m.polygon,1) >= 3
            P = m.polygon + [base_cx, base_cy];
            plot(axCS,[P(:,1);P(1,1)],[P(:,2);P(1,2)],'-');
        else
            [vx,vy] = muscle_ellipse_vertices(m);
            plot(axCS,vx,vy,'-');
        end
    end
    % Электроды всех массивов + ground
    for k=1:numel(cfg.electrode_arrays)
        a = cfg.electrode_arrays{k};
        n = 3;
        rot = getf(a,'rotation_deg',0) * pi/180;
        offsets = ((1:n) - (n+1)/2) * a.spacing;
        elec_angles = a.angle + (offsets * sin(rot) / Rskin) * (180/pi);

        % Если custom ref — E2 в другом месте
        rp = getf(a,'ref_position',struct());
        if getf(rp,'custom_enabled',false)
            elec_angles(2) = getf(rp,'angle',a.angle);
        end

        for e=1:n
            ang_e = elec_angles(e)*pi/180;
            ex = Rskin*cos(ang_e);
            ey = Rskin*sin(ang_e);
            if e == 2
                % Центральный (ref) электрод — отличающийся маркер
                plot(axCS,ex,ey,'bs','MarkerSize',6,'MarkerFaceColor',[0.3 0.5 1]);
            else
                plot(axCS,ex,ey,'ks','MarkerSize',6);
            end
        end
        % Подпись у E1
        ang1 = elec_angles(1)*pi/180;
        text(axCS,Rskin*cos(ang1),Rskin*sin(ang1),sprintf(' %s',a.name),'FontSize',9);

        % Ground
        ge = getf(a,'ground_electrode',struct());
        if getf(ge,'enabled',false)
            gnd_ang = getf(ge,'angle',0)*pi/180;
            gx = Rskin*cos(gnd_ang);
            gy = Rskin*sin(gnd_ang);
            plot(axCS,gx,gy,'gv','MarkerSize',8,'MarkerFaceColor',[0 0.7 0]);
            text(axCS,gx,gy,' GND','FontSize',7,'Color',[0 0.5 0]);
        end
    end
    axis(axCS,[-Rskin Rskin -Rskin Rskin]*1.05);
    hold(axCS,'off');
end

function on_close()
        % Финальный коммит текущих значений со вкладок помех
        commit_imbalance();
        commit_refgnd();

        cfg = getcfg();

        % === Сетевая помеха (всегда из контролов) ===
        if ~isfield(cfg,'interference'), cfg.interference = struct(); end
        if ~isfield(cfg.interference,'mains'), cfg.interference.mains = struct(); end
        cfg.interference.mains.enabled = cbMainsEnabled.Value;
        cfg.interference.mains.frequency = edMainsFreq.Value;
        cfg.interference.mains.amplitude_Vp = edMainsAmp.Value * 1e-3;
        cfg.interference.mains.n_harmonics = edMainsHarm.Value;
        cfg.interference.mains.harmonic_decay = edMainsHarmDecay.Value;
        cfg.interference.mains.dc_offset_V = edMainsDC.Value * 1e-3;
        cfg.interference.mains.dc_offset_spread_V = edMainsDCspread.Value * 1e-3;
        cfg.interference.mains.phase_noise_deg = edMainsPhase.Value;
        cfg.interference.mains.amplitude_noise = edMainsAmpNoise.Value;

        % === Объединение земель ===
        if ~isfield(cfg.interference,'ground_merge'), cfg.interference.ground_merge = struct(); end
        cfg.interference.ground_merge.enabled = cbGMEnabled.Value;
        gm_groups_out = {};
        try
            g1 = strtrim(edGMGroup1.Value);
            if ~isempty(g1), gm_groups_out{end+1} = eval(g1); end
            g2 = strtrim(edGMGroup2.Value);
            if ~isempty(g2), gm_groups_out{end+1} = eval(g2); end
            g3 = strtrim(edGMGroup3.Value);
            if ~isempty(g3), gm_groups_out{end+1} = eval(g3); end
        catch
        end
        cfg.interference.ground_merge.groups = gm_groups_out;

        cfg = validate_cfg_for_core(cfg);
        set_cfg_cb(cfg);
        delete(fig);
    end
end


function draw_electrode_rects(ax, cfg, a, zz, ang)
    % Draw electrodes as rectangles on unwrap: x = z (m), y = arc-length s (m).
    % zz(i) = z-coordinate of electrode i, ang(i) = angle in degrees.
    % rotation_deg rotates each rectangle in the tangent plane.
    Rskin = cfg.geometry.radius_outer;

    w_z  = max(a.size(1), 1e-4);  % along z (m)
    h_arc = max(a.size(2), 1e-4); % along arc length (m)

    for i=1:numel(zz)
        zc_i = zz(i);
        sc_i = Rskin * (ang(i) * pi / 180);

        dx = w_z/2;
        dy = h_arc/2;

        px = [zc_i-dx, zc_i+dx, zc_i+dx, zc_i-dx];
        py = [sc_i-dy, sc_i-dy, sc_i+dy, sc_i+dy];

        patch(ax, px, py, [0 0 0], 'FaceAlpha', 0.08, 'EdgeColor', 'none');
        plot(ax, [px px(1)], [py py(1)], '-');
    end
end

function names = array_names(cfg)
    names = cell(1,numel(cfg.electrode_arrays));
    for k=1:numel(cfg.electrode_arrays), names{k} = cfg.electrode_arrays{k}.name; end
end


function v = get_afield(a, field, def)
    if isfield(a,field), v = a.(field); else, v = def; end
end

function draw_rect_unwrap(ax, zc, angc, w, hdeg, rotdeg)
    % Draw a rotated rectangle in unwrap coordinates (z vs angle degrees)
    % Center: (zc, angc). Width along z: w. Height along angle: hdeg.
    % Rotation in degrees around center in this coordinate system.
    th = rotdeg*pi/180;
    dx = w/2; dy = hdeg/2;
    pts = [-dx -dy; dx -dy; dx dy; -dx dy]';
    R = [cos(th) -sin(th); sin(th) cos(th)];
    pr = R*pts;
    X = zc + pr(1,:); 
    Y = angc + pr(2,:);
    patch(ax, X, Y, [0.2 0.2 0.2], 'FaceAlpha', 0.10, 'EdgeColor', [0.2 0.2 0.2]);
end

function F_ref = core_force_profile_eval(t, fp)
    % Evaluate target force profile at time t (seconds).
    % Supports: constant, step, ramp_hold, trapezoid, sine, custom

    % Custom points: robust interp with 0/1/2+ points
    if isfield(fp,'custom_data') && ~isempty(fp.custom_data)
        td = fp.custom_data(:,1);
        fd = fp.custom_data(:,2);

        mask = isfinite(td) & isfinite(fd);
        td = td(mask); fd = fd(mask);

        if numel(td) < 2
            if isempty(td), F_ref = 0; else, F_ref = fd(1); end
            return;
        end

        [tds, order] = sort(td(:));
        fds = fd(order);
        [tds_u, ia] = unique(tds,'stable');
        fds_u = fds(ia);

        if numel(tds_u) < 2
            F_ref = fds_u(1);
            return;
        end

        F_ref = interp1(tds_u, fds_u, t, 'linear', 0);
        if ~isfinite(F_ref), F_ref = 0; end
        return;
    end

    % Parametric profiles
    typ = getf(fp,'type','constant');
    F_max = getf(fp,'F_max',0.3);

    switch typ
        case 'constant'
            F_ref = F_max;

        case 'step'
            t0 = getf(fp,'step_time',0.5);
            if t < t0, F_ref = 0; else, F_ref = F_max; end

        case 'ramp_hold'
            ramp_t = getf(fp,'ramp_time',0.25);
            hold_t = getf(fp,'hold_time',0.35);
            if t < ramp_t
                F_ref = F_max * (t / max(ramp_t,eps));
            elseif t < ramp_t + hold_t
                F_ref = F_max;
            else
                % gentle decay tail (UI preview only)
                F_ref = F_max * exp(-(t - ramp_t - hold_t) / 1.0);
            end

        case 'trapezoid'
            ramp_up = getf(fp,'ramp_time',0.25);
            hold_t = getf(fp,'hold_time',0.35);
            ramp_down = getf(fp,'ramp_down_time',0.25);
            t1 = ramp_up;
            t2 = ramp_up + hold_t;
            t3 = ramp_up + hold_t + ramp_down;

            if t < 0
                F_ref = 0;
            elseif t < t1
                F_ref = F_max * (t / max(ramp_up,eps));
            elseif t < t2
                F_ref = F_max;
            elseif t < t3
                F_ref = F_max * max(0, (t3 - t) / max(ramp_down,eps));
            else
                F_ref = 0;
            end

        case 'sine'
            f = getf(fp,'frequency',0.5);
            F_ref = F_max * (0.5 + 0.5*sin(2*pi*f*t));

        case 'pulse'
            t0 = getf(fp,'step_time',0.2);
            dur = getf(fp,'pulse_duration',0.1);
            if t >= t0 && t < t0 + dur
                F_ref = F_max;
            else
                F_ref = 0;
            end

        otherwise
            % Unknown type -> safe default
            F_ref = 0;
    end

    if ~isfinite(F_ref), F_ref = 0; end
end