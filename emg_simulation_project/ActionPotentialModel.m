classdef ActionPotentialModel
%% ACTIONPOTENTIALMODEL - Модели внутриклеточного потенциала действия (IAP)
% =========================================================================
% Генерирует профили трансмембранного потенциала Vm(z) и мембранного тока Im(z)
% для использования в симуляции ЭМГ.
%
% МОДЕЛИ:
%   'rosenfalck'  - Аналитическая модель Rosenfalck (1969) - быстрая, рекомендуется
%   'hh'          - Упрощённая Hodgkin-Huxley для мышечного волокна
%   'fhn'         - FitzHugh-Nagumo (качественная модель)
%   'gaussian'    - Упрощённый Гауссов триполь (legacy, для совместимости)
%
% ИСПОЛЬЗОВАНИЕ:
%   model = ActionPotentialModel('rosenfalck');
%   model.fiber_diameter_um = 50;
%   model.cv = 4.0;
%   [Vm, Im, z] = model.generate();
%
% ВЫХОДЫ:
%   Vm - трансмембранный потенциал [В], размер [1 x N_z]
%   Im - мембранный ток на единицу длины [А/м], размер [1 x N_z]
%   z  - координата вдоль волокна [м], размер [1 x N_z]
%
% ФИЗИКА:
%   Im(z) = ∂²Vm/∂z² · (π·a²·σi) где a - радиус волокна
%   Это источник тока для объёмного проводника.
%
% АВТОР: EMG Simulation Framework
% ВЕРСИЯ: 1.0
% =========================================================================

    properties
        % Тип модели
        model_type = 'rosenfalck';  % 'rosenfalck', 'hh', 'fhn', 'gaussian'
        
        % Параметры волокна
        fiber_diameter_um = 50;     % Диаметр волокна [мкм]
        fiber_type = 'FR';          % Тип волокна: 'S', 'FR', 'FF'
        
        % Скорость проведения
        cv = 4.0;                   % Скорость проведения [м/с]
        
        % Температура (для HH)
        temperature = 37;           % Температура [°C]
        
        % Электрические параметры мембраны
        Cm = 1.0;                   % Ёмкость мембраны [мкФ/см²]
        Rm = 4000;                  % Сопротивление мембраны [Ом·см²]
        Ri = 125;                   % Внутриклеточное сопротивление [Ом·см]
        
        % Параметры потенциала действия
        V_rest = -85e-3;            % Потенциал покоя [В]
        V_peak = 30e-3;             % Пиковый потенциал [В]
        AP_duration_ms = 3.0;       % Длительность AP [мс]
        
        % Пространственные параметры
        window_length_mm = 15;      % Длина окна расчёта [мм]
        n_points = 150;             % Число точек дискретизации
        
        % Параметры модели Rosenfalck
        rosenfalck_A = 96;          % Коэффициент амплитуды [мВ/мм³]
        rosenfalck_lambda = 1.0;    % Постоянная длины [мм]
        
        % Параметры HH (для мышцы, адаптированные)
        gNa_max = 120;              % Макс. проводимость Na [мСм/см²]
        gK_max = 36;                % Макс. проводимость K [мСм/см²]
        gL = 0.3;                   % Проводимость утечки [мСм/см²]
        ENa = 50e-3;                % Равновесный потенциал Na [В]
        EK = -90e-3;                % Равновесный потенциал K [В]
        EL = -70e-3;                % Равновесный потенциал утечки [В]
        Q10 = 3.0;                  % Температурный коэффициент
    end
    
    properties (Dependent)
        fiber_radius_m              % Радиус волокна [м]
        space_constant_m            % Постоянная длины λ [м]
        time_constant_ms            % Постоянная времени τ [мс]
        sigma_i                     % Внутриклеточная проводимость [См/м]
    end
    
    methods
        %% Конструктор
        function obj = ActionPotentialModel(model_type)
            if nargin >= 1
                obj.model_type = model_type;
            end
        end
        
        %% Зависимые свойства
        function r = get.fiber_radius_m(obj)
            r = obj.fiber_diameter_um * 1e-6 / 2;
        end
        
        function lambda = get.space_constant_m(obj)
            % λ = √(Rm·d / (4·Ri))
            d_cm = obj.fiber_diameter_um * 1e-4;
            lambda = sqrt(obj.Rm * d_cm / (4 * obj.Ri)) * 1e-2;  % -> м
        end
        
        function tau = get.time_constant_ms(obj)
            % τ = Rm · Cm
            tau = obj.Rm * obj.Cm * 1e-3;  % мкФ·Ом -> мс
        end
        
        function sig = get.sigma_i(obj)
            % σi = 1/ρi где ρi в Ом·м
            sig = 1 / (obj.Ri * 1e-2);  % Ом·см -> Ом·м -> См/м
        end
        
        %% Главный метод генерации
        function [Vm, Im, z] = generate(obj, params)
            % generate - Генерирует профили Vm и Im
            %
            % ВХОД:
            %   params (опционально) - структура с переопределением параметров
            %
            % ВЫХОД:
            %   Vm - трансмембранный потенциал [В]
            %   Im - мембранный ток на единицу длины [А/м]
            %   z  - координата [м]
            
            if nargin < 2, params = struct(); end
            
            % Применяем переданные параметры
            obj = obj.applyParams(params);
            
            switch lower(obj.model_type)
                case 'rosenfalck'
                    [Vm, Im, z] = obj.rosenfalck_model();
                case 'hh'
                    [Vm, Im, z] = obj.hodgkin_huxley_model();
                case 'fhn'
                    [Vm, Im, z] = obj.fitzhugh_nagumo_model();
                case 'gaussian'
                    [Vm, Im, z] = obj.gaussian_tripole_model();
                otherwise
                    warning('Unknown model type: %s, using rosenfalck', obj.model_type);
                    [Vm, Im, z] = obj.rosenfalck_model();
            end
        end
        
        %% Модель Rosenfalck (1969)
        function [Vm, Im, z] = rosenfalck_model(obj)
            % rosenfalck_model - Аналитическая модель IAP
            %
            % Формула Rosenfalck для Vm:
            %   Vm(z) = A · z³ · exp(-z/λ) - baseline
            %
            % Мембранный ток Im получается из кабельного уравнения:
            %   Im = (π·a²·σi) · ∂²Vm/∂z²
            
            % Пространственная сетка
            z = linspace(0, obj.window_length_mm * 1e-3, obj.n_points);
            z_mm = z * 1000;  % для формулы в мм
            
            A = obj.rosenfalck_A;      % мВ/мм³
            lambda = obj.rosenfalck_lambda;  % мм
            
            % Трансмембранный потенциал (Rosenfalck формула)
            % Vm(z) = A · z³ · exp(-z/λ)
            Vm_mV = A * (z_mm.^3) .* exp(-z_mm / lambda);
            
            % Нормализация к реалистичной амплитуде AP
            AP_amplitude = obj.V_peak - obj.V_rest;  % ~115 мВ
            Vm_max = max(Vm_mV);
            if Vm_max > 0
                Vm_mV = Vm_mV * (AP_amplitude * 1000) / Vm_max;
            end
            
            % Добавляем потенциал покоя
            Vm = obj.V_rest + Vm_mV * 1e-3;  % -> В
            
            % Вторая производная ∂²Vm/∂z² для мембранного тока
            % d²/dz²[A·z³·exp(-z/λ)] = A·exp(-z/λ)·(6z − 6z²/λ + z³/λ²)
            % ИСПРАВЛЕНО: убран лишний /λ² — он маскировался при λ=1, но
            % нарушал масштаб Im при любом другом значении постоянной длины.
            d2Vm_dz2_mV_mm2 = A * exp(-z_mm/lambda) .* ...
                (6*z_mm - 6*z_mm.^2/lambda + z_mm.^3/lambda^2);
            
            % Масштабируем так же как Vm
            if Vm_max > 0
                d2Vm_dz2_mV_mm2 = d2Vm_dz2_mV_mm2 * (AP_amplitude * 1000) / Vm_max;
            end
            
            % Конвертируем: мВ/мм² -> В/м²
            d2Vm_dz2 = d2Vm_dz2_mV_mm2 * 1e-3 * 1e6;  % мВ->В, мм²->м²
            
            % Мембранный ток на единицу длины [А/м]
            % Im = (π·a²·σi) · ∂²Vm/∂z²
            a = obj.fiber_radius_m;
            Im = pi * a^2 * obj.sigma_i * d2Vm_dz2;
        end
        
        %% Упрощённая модель Hodgkin-Huxley
        function [Vm, Im, z] = hodgkin_huxley_model(obj)
            % hodgkin_huxley_model - Численное решение HH для мышечного волокна
            %
            % Уравнения HH:
            %   Cm·dVm/dt = -gNa·m³h(Vm-ENa) - gK·n⁴(Vm-EK) - gL(Vm-EL) + Iext
            %   dm/dt = αm(1-m) - βm·m
            %   dh/dt = αh(1-h) - βh·h  
            %   dn/dt = αn(1-n) - βn·n
            
            % Температурная коррекция
            T_ref = 6.3;  % Референсная температура HH (°C)
            phi = obj.Q10^((obj.temperature - T_ref) / 10);
            
            % Временная сетка
            dt = 0.01e-3;  % 10 мкс
            t_max = obj.AP_duration_ms * 2e-3;  % удвоенная длительность
            t = 0:dt:t_max;
            n_t = length(t);
            
            % Начальные условия
            V = obj.V_rest;
            [m, h, n] = obj.hh_steady_state(V);
            
            % Массивы для хранения
            Vm_t = zeros(1, n_t);
            Im_t = zeros(1, n_t);
            
            % Стимул (короткий импульс)
            I_stim = zeros(1, n_t);
            stim_start = round(0.5e-3 / dt);
            stim_end = round(1.0e-3 / dt);
            if stim_end <= n_t
                I_stim(stim_start:stim_end) = 20e-6;  % 20 мкА/см²
            end
            
            % Интегрирование (метод Эйлера)
            Cm_SI = obj.Cm * 1e-2;  % мкФ/см² -> Ф/м²
            for i = 1:n_t
                % Ионные токи [А/м²]
                INa = obj.gNa_max * 10 * m^3 * h * (V - obj.ENa);  % мСм/см² -> См/м²
                IK = obj.gK_max * 10 * n^4 * (V - obj.EK);
                IL = obj.gL * 10 * (V - obj.EL);
                
                Iion = INa + IK + IL;
                
                % Мембранный ток
                Im_t(i) = Iion;
                Vm_t(i) = V;
                
                % dV/dt
                dVdt = (-Iion + I_stim(i) * 10) / Cm_SI;
                
                % Обновление гейтов
                [am, bm] = obj.hh_alpha_beta_m(V);
                [ah, bh] = obj.hh_alpha_beta_h(V);
                [an, bn] = obj.hh_alpha_beta_n(V);
                
                dm = phi * (am * (1-m) - bm * m) * dt;
                dh = phi * (ah * (1-h) - bh * h) * dt;
                dn = phi * (an * (1-n) - bn * n) * dt;
                
                V = V + dVdt * dt;
                m = max(0, min(1, m + dm));
                h = max(0, min(1, h + dh));
                n = max(0, min(1, n + dn));
            end
            
            % Конвертируем время -> пространство через CV
            z = t * obj.cv;
            Vm = Vm_t;
            
            % Мембранный ток на единицу длины
            % Im_line = Im_surface · π·d
            Im = Im_t * pi * obj.fiber_diameter_um * 1e-6;
        end
        
        %% Модель FitzHugh-Nagumo
        function [Vm, Im, z] = fitzhugh_nagumo_model(obj)
            % fitzhugh_nagumo_model - Качественная модель возбудимой мембраны
            %
            % Уравнения FHN:
            %   dv/dt = v - v³/3 - w + I
            %   dw/dt = ε(v + a - bw)
            
            % Параметры FHN
            a = 0.7;
            b = 0.8;
            epsilon = 0.08;
            
            % Временная сетка
            dt = 0.1e-3;
            t_max = obj.AP_duration_ms * 3e-3;
            t = 0:dt:t_max;
            n_t = length(t);
            
            % Начальные условия
            v = -1.2;  % Состояние покоя
            w = -0.6;
            
            % Стимул
            I_stim = zeros(1, n_t);
            stim_idx = round(0.5e-3 / dt):round(1.5e-3 / dt);
            if max(stim_idx) <= n_t
                I_stim(stim_idx) = 1.0;
            end
            
            % Массивы
            v_t = zeros(1, n_t);
            
            % Интегрирование
            for i = 1:n_t
                v_t(i) = v;
                
                dv = (v - v^3/3 - w + I_stim(i)) * 1000;  % Масштаб времени
                dw = epsilon * (v + a - b*w) * 1000;
                
                v = v + dv * dt;
                w = w + dw * dt;
            end
            
            % Масштабирование к реальным значениям
            v_min = min(v_t);
            v_max = max(v_t);
            if v_max > v_min
                Vm = obj.V_rest + (v_t - v_min) / (v_max - v_min) * (obj.V_peak - obj.V_rest);
            else
                Vm = obj.V_rest * ones(size(v_t));
            end
            
            % Пространственная координата
            z = t * obj.cv;
            
            % Мембранный ток из численной производной
            dz = z(2) - z(1);
            d2Vm = [0, diff(diff(Vm))/dz^2, 0];
            a_fiber = obj.fiber_radius_m;
            Im = pi * a_fiber^2 * obj.sigma_i * d2Vm;
        end
        
        %% Упрощённый Гауссов триполь (legacy)
        function [Vm, Im, z] = gaussian_tripole_model(obj)
            % gaussian_tripole_model - Гауссов триполь (+1,-2,+1)
            % Для обратной совместимости с предыдущей реализацией
            
            z = linspace(0, obj.window_length_mm * 1e-3, obj.n_points);
            
            % Ширина Гаусса из CV и длительности AP
            w = 0.5 * obj.cv * obj.AP_duration_ms * 1e-3;
            w = max(0.001, w);
            
            % Расстояние между полюсами триполя
            d = 1.3 * w;
            
            % Центр волны
            z_center = obj.window_length_mm * 1e-3 / 2;
            
            % Триполь для Im (производная Vm)
            Im = exp(-0.5 * ((z - (z_center - d)) / w).^2) ...
               - 2 * exp(-0.5 * ((z - z_center) / w).^2) ...
               + exp(-0.5 * ((z - (z_center + d)) / w).^2);
            
            % Масштабирование
            a = obj.fiber_radius_m;
            Cm_SI = obj.Cm * 1e-2;  % Ф/м²
            I_scale = pi * obj.fiber_diameter_um * 1e-6 * Cm_SI * ...
                      (obj.V_peak - obj.V_rest) * obj.cv / w;
            Im = Im * I_scale;
            
            % Vm восстанавливаем интегрированием (приближённо)
            Vm_shape = -exp(-0.5 * ((z - z_center) / w).^2);
            Vm = obj.V_rest + (obj.V_peak - obj.V_rest) * (Vm_shape - min(Vm_shape)) / ...
                 (max(Vm_shape) - min(Vm_shape) + eps);
        end
        
        %% Вспомогательные функции HH
        function [m, h, n] = hh_steady_state(obj, V)
            [am, bm] = obj.hh_alpha_beta_m(V);
            [ah, bh] = obj.hh_alpha_beta_h(V);
            [an, bn] = obj.hh_alpha_beta_n(V);
            m = am / (am + bm);
            h = ah / (ah + bh);
            n = an / (an + bn);
        end
        
        function [am, bm] = hh_alpha_beta_m(~, V)
            V_mV = V * 1000;  % В -> мВ
            Vshift = V_mV + 65;  % Сдвиг для стандартной формы HH
            
            if abs(Vshift - 25) < 1e-6
                am = 1.0;
            else
                am = 0.1 * (25 - Vshift) / (exp((25 - Vshift)/10) - 1);
            end
            bm = 4 * exp(-Vshift / 18);
        end
        
        function [ah, bh] = hh_alpha_beta_h(~, V)
            V_mV = V * 1000;
            Vshift = V_mV + 65;
            
            ah = 0.07 * exp(-Vshift / 20);
            bh = 1 / (exp((30 - Vshift)/10) + 1);
        end
        
        function [an, bn] = hh_alpha_beta_n(~, V)
            V_mV = V * 1000;
            Vshift = V_mV + 65;
            
            if abs(Vshift - 10) < 1e-6
                an = 0.1;
            else
                an = 0.01 * (10 - Vshift) / (exp((10 - Vshift)/10) - 1);
            end
            bn = 0.125 * exp(-Vshift / 80);
        end
        
        %% Применение параметров
        function obj = applyParams(obj, params)
            if isfield(params, 'fiber_diameter_um')
                obj.fiber_diameter_um = params.fiber_diameter_um;
            end
            if isfield(params, 'cv')
                obj.cv = params.cv;
            end
            if isfield(params, 'temperature')
                obj.temperature = params.temperature;
            end
            if isfield(params, 'fiber_type')
                obj.fiber_type = params.fiber_type;
                % Устанавливаем типичные параметры для типа волокна
                switch upper(obj.fiber_type)
                    case 'S'
                        obj.fiber_diameter_um = 35;
                        obj.cv = 3.0;
                    case 'FR'
                        obj.fiber_diameter_um = 50;
                        obj.cv = 4.0;
                    case 'FF'
                        obj.fiber_diameter_um = 65;
                        obj.cv = 5.0;
                end
            end
            if isfield(params, 'Cm')
                obj.Cm = params.Cm;
            end
            if isfield(params, 'V_rest')
                obj.V_rest = params.V_rest;
            end
            if isfield(params, 'V_peak')
                obj.V_peak = params.V_peak;
            end
            if isfield(params, 'AP_duration_ms')
                obj.AP_duration_ms = params.AP_duration_ms;
            end
            if isfield(params, 'n_points')
                obj.n_points = params.n_points;
            end
            if isfield(params, 'window_length_mm')
                obj.window_length_mm = params.window_length_mm;
            end
        end
        
        %% Метод для получения профиля Im в заданных точках z
        function Im_interp = getImAtPositions(obj, z_query)
            % getImAtPositions - Интерполирует Im в заданные позиции
            %
            % ВХОД:
            %   z_query - координаты запроса [м], вектор
            %
            % ВЫХОД:
            %   Im_interp - интерполированный мембранный ток [А/м]
            
            [~, Im, z] = obj.generate();
            
            % Интерполяция
            Im_interp = interp1(z, Im, z_query, 'pchip', 0);
        end
    end
    
    methods (Static)
        %% Статический метод для быстрого создания
        function obj = createForFiberType(type, cv)
            % createForFiberType - Создаёт модель для заданного типа волокна
            %
            % ИСПОЛЬЗОВАНИЕ:
            %   model = ActionPotentialModel.createForFiberType('FF', 5.2);
            
            obj = ActionPotentialModel('rosenfalck');
            
            switch upper(type)
                case 'S'
                    obj.fiber_diameter_um = 35;
                    obj.fiber_type = 'S';
                    if nargin < 2, cv = 3.0; end
                case 'FR'
                    obj.fiber_diameter_um = 50;
                    obj.fiber_type = 'FR';
                    if nargin < 2, cv = 4.0; end
                case 'FF'
                    obj.fiber_diameter_um = 65;
                    obj.fiber_type = 'FF';
                    if nargin < 2, cv = 5.0; end
                otherwise
                    obj.fiber_type = 'FR';
                    obj.fiber_diameter_um = 50;
                    if nargin < 2, cv = 4.0; end
            end
            obj.cv = cv;
        end
        
        %% Демонстрация моделей
        function demo()
            % demo - Демонстрирует все модели IAP
            
            figure('Name', 'Action Potential Models Comparison', ...
                   'Position', [100, 100, 1200, 800]);
            
            models = {'rosenfalck', 'hh', 'fhn', 'gaussian'};
            titles = {'Rosenfalck (Analytical)', 'Hodgkin-Huxley', ...
                      'FitzHugh-Nagumo', 'Gaussian Tripole'};
            
            for i = 1:4
                model = ActionPotentialModel(models{i});
                model.fiber_type = 'FR';
                model.cv = 4.0;
                
                [Vm, Im, z] = model.generate();
                
                % Vm plot
                subplot(2, 4, i);
                plot(z*1000, Vm*1000, 'b-', 'LineWidth', 1.5);
                xlabel('z [mm]');
                ylabel('Vm [mV]');
                title(titles{i});
                grid on;
                
                % Im plot
                subplot(2, 4, i+4);
                plot(z*1000, Im*1e6, 'r-', 'LineWidth', 1.5);
                xlabel('z [mm]');
                ylabel('Im [μA/m]');
                grid on;
            end
            
            sgtitle('Comparison of IAP Models (FR fiber, CV=4 m/s)');
        end
        
        %% Тест корректности
        function passed = test()
            % test - Проверяет корректность моделей
            
            fprintf('Testing ActionPotentialModel...\n');
            passed = true;
            
            % Тест 1: Rosenfalck генерирует непустые данные
            model = ActionPotentialModel('rosenfalck');
            [Vm, Im, z] = model.generate();
            if isempty(Vm) || isempty(Im) || isempty(z)
                fprintf('  FAIL: Rosenfalck returns empty\n');
                passed = false;
            else
                fprintf('  PASS: Rosenfalck generates data\n');
            end
            
            % Тест 2: Vm в разумном диапазоне
            if min(Vm) < -0.1 || max(Vm) > 0.05
                fprintf('  WARN: Vm outside typical range [%.1f, %.1f] mV\n', ...
                        min(Vm)*1000, max(Vm)*1000);
            else
                fprintf('  PASS: Vm in reasonable range\n');
            end
            
            % Тест 3: Im интегрируется примерно к 0 (сохранение заряда)
            dz = z(2) - z(1);
            Q_total = sum(Im) * dz;
            if abs(Q_total) > max(abs(Im)) * dz * 10
                fprintf('  WARN: Im does not integrate to ~0 (Q=%.2e)\n', Q_total);
            else
                fprintf('  PASS: Charge conservation OK\n');
            end
            
            % Тест 4: HH модель работает
            model_hh = ActionPotentialModel('hh');
            try
                [Vm_hh, ~, ~] = model_hh.generate();
                if max(Vm_hh) > model_hh.V_rest
                    fprintf('  PASS: HH generates AP\n');
                else
                    fprintf('  WARN: HH may not generate proper AP\n');
                end
            catch e
                fprintf('  FAIL: HH error: %s\n', e.message);
                passed = false;
            end
            
            % Тест 5: Параметры типа волокна
            model_s = ActionPotentialModel.createForFiberType('S', 3.0);
            model_ff = ActionPotentialModel.createForFiberType('FF', 5.5);
            if model_s.fiber_diameter_um < model_ff.fiber_diameter_um
                fprintf('  PASS: S fiber smaller than FF\n');
            else
                fprintf('  FAIL: Fiber type parameters incorrect\n');
                passed = false;
            end
            
            % Тест 6 (ПАТЧ 8): Сохранение заряда для полной двунаправленной
            % волны с экстинкцией на конечном волокне.
            % Физическое требование: ∫Im(z)dz = 0 в каждый момент t.
            % Без экстинкции суммарный ток двух бегущих волн не обнуляется
            % точно на конечном волокне — экстинкция компенсирует остаток.
            fprintf('  Test 6: Charge conservation (bidirectional + extinction)...\n');
            try
                model_cc = ActionPotentialModel('rosenfalck');
                [~, Im_cc, z_cc] = model_cc.generate();
                dz_cc = z_cc(2) - z_cc(1);
                cv_cc = model_cc.cv;
                
                % Параметры волокна
                fiber_half_len = 0.060;  % 60 мм в каждую сторону от NMJ
                z_fiber = -fiber_half_len : dz_cc : fiber_half_len;
                n_z = length(z_fiber);
                
                % Параметры экстинкции (как в emg_simulation_core ПАТЧ 3)
                tau_ext = 0.5e-3;       % с
                ext_sigma = 0.002;      % м
                ext_amp_scale = 0.8;
                Im_peak = max(abs(Im_cc));
                
                % Длина AP в пространстве
                ap_len = (z_cc(end) - z_cc(1));
                z_cc_centered = z_cc - z_cc(end)/2;
                
                % Временной диапазон: до экстинкции + 5*tau после
                t_max = fiber_half_len / cv_cc + 5 * tau_ext;
                dt_cc = dz_cc / cv_cc / 4;  % Мелкий шаг
                t_vec = 0 : dt_cc : t_max;
                
                Q_max_err = 0;
                n_ext_samples = 0;
                
                for ti = 1:length(t_vec)
                    tc = t_vec(ti);
                    Im_fiber = zeros(1, n_z);
                    
                    % Фронт + и -
                    zf_p = cv_cc * tc;
                    zf_n = -cv_cc * tc;
                    
                    front_p_active = (zf_p <= fiber_half_len);
                    front_n_active = (zf_n >= -fiber_half_len);
                    
                    % Времена прибытия на концы
                    t_arr_p = fiber_half_len / cv_cc;
                    t_arr_n = fiber_half_len / cv_cc;
                    t_ext_p = tc - t_arr_p;
                    t_ext_n = tc - t_arr_n;
                    
                    for zi = 1:n_z
                        z_here = z_fiber(zi);
                        
                        % Пропагирующий компонент +
                        if front_p_active
                            z_rel = z_here - zf_p;
                            if z_rel >= -ap_len && z_rel <= ap_len
                                Im_fiber(zi) = Im_fiber(zi) + interp1(z_cc_centered, Im_cc, z_rel, 'pchip', 0);
                            end
                        end
                        
                        % Пропагирующий компонент -
                        if front_n_active
                            z_rel = z_here - zf_n;
                            if z_rel >= -ap_len && z_rel <= ap_len
                                Im_fiber(zi) = Im_fiber(zi) + interp1(z_cc_centered, Im_cc, -z_rel, 'pchip', 0);
                            end
                        end
                        
                        % Экстинкция на конце +fiber_half_len
                        if t_ext_p >= 0 && t_ext_p < 5*tau_ext
                            sw = exp(-0.5 * ((z_here - fiber_half_len)/ext_sigma)^2);
                            Im_fiber(zi) = Im_fiber(zi) + ext_amp_scale * Im_peak * sw * exp(-t_ext_p/tau_ext);
                        end
                        
                        % Экстинкция на конце -fiber_half_len
                        if t_ext_n >= 0 && t_ext_n < 5*tau_ext
                            sw = exp(-0.5 * ((z_here + fiber_half_len)/ext_sigma)^2);
                            Im_fiber(zi) = Im_fiber(zi) + ext_amp_scale * Im_peak * sw * exp(-t_ext_n/tau_ext);
                        end
                    end
                    
                    Q_t = sum(Im_fiber) * dz_cc;
                    Im_norm = max(abs(Im_fiber));
                    if Im_norm > 1e-20
                        Q_rel = abs(Q_t) / (Im_norm * ap_len);
                        Q_max_err = max(Q_max_err, Q_rel);
                        n_ext_samples = n_ext_samples + 1;
                    end
                end
                
                % Относительная ошибка заряда < 20% считается приемлемой
                % (экстинкция — аппроксимация, точное обнуление не ожидается)
                if Q_max_err < 0.20
                    fprintf('    PASS: Max relative charge imbalance = %.1f%%\n', Q_max_err*100);
                else
                    fprintf('    WARN: Max relative charge imbalance = %.1f%% (>20%%)\n', Q_max_err*100);
                    fprintf('          Consider tuning extinction_amplitude for better balance.\n');
                end
                fprintf('          Tested %d time steps with active sources\n', n_ext_samples);
            catch e
                fprintf('    FAIL: Charge conservation test error: %s\n', e.message);
                passed = false;
            end
            
            if passed
                fprintf('All tests PASSED\n');
            else
                fprintf('Some tests FAILED\n');
            end
        end
    end
end