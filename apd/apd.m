%% Avalanche photodiode
classdef apd < handle
    properties
        Gain % Gain
        ka   % impact ionization factor
        GainBW % Gain x Bandwidth product
        R    % responsivity
        Id   % dark current
    end
    properties (Dependent)
        Fa % excess noise factor
        GaindB % Gain in dB 
    end
    
    properties (Constant, Hidden)
        h = 6.62606957e-34; % Planck
        q = 1.60217657e-19; % electron charge
        c = 299792458;      % speed of light
    end
    
    properties (Constant, GetAccess=private)
        cdf_accuracy = 1-1e-4; % Required accuracy of the cdf (i.e., pmf will have the minimum number of points that satistifes that sum pmf > cdf_accuracy.)
        Niterations = 1e6; % maximum number of iterations in a while loop
        Ptail = 1e-6; % probability of clipped tail
    end
    
    properties (Dependent, GetAccess=private)
        a % auxiliary variable G = 1/(1-ab)
        b % auxiliary variable b = 1/(1-ka)
    end
    
    methods (Access=private)     
        function ber = calc_apd_ber(this, PtxdBm, Gapd, mpam, tx, fiber, rx, sim)
            %% Iterate BER calculation: for given PtxdBm and Gapd calculates BER

            % Set power level
            tx.Ptx = 1e-3*10^(PtxdBm/10);

            % Set APD gain
            this.Gain = Gapd; % linear units

            % Auxiliary variables
            Deltaf = rx.elefilt.noisebw(sim.fs)/2; % electric filter one-sided noise bandwidth
            % function to calculate noise std
            varTherm = rx.N0*Deltaf; % variance of thermal noise

            if isfield(sim, 'RIN') && sim.RIN
                varRIN =  @(Plevel) 10^(tx.RIN/10)*Plevel.^2*Deltaf;
            else
                varRIN = @(Plevel) 0;
            end

            % Noise std for the level Plevel
            noise_std = @(Plevel) sqrt(varTherm + varRIN(Plevel) + this.varShot(Plevel/this.Gain, Deltaf));

            % Level spacing optimization
            if mpam.optimize_level_spacing
                mpam.optimize_level_spacing_gauss_approx(sim.BERtarget, tx.rexdB, noise_std);  
            end

             mpam.adjust_levels(tx.Ptx, tx.rexdB);

             % if sim.awgn is set, then use AWGN approximation to
             % calculate the BER
             if isfield(sim, 'awgn') && sim.awgn
                ber = mpam.ber_awgn(noise_std);
             else
                 [~, ber] = ber_apd_doubly_stochastic(mpam, tx, fiber, this, rx, sim);
             end
        end   
        
%         function M = Ms(this, s)
%             options = optimoptions('fsolve', 'Display', 'off');
%             exitflag = 2;
%             k = 1;
%             while exitflag ~= 1 && k < 10
%                 [M, ~, exitflag] = fsolve(@(M) M*(1 + this.a*(M-1))^(-this.b) - exp(s), 4*randn(1), options);
%                 k = k + 1;
%             end
%             if exitflag ~= 1 
%                 warning('Calculation of M did not converge');
%             end  
%         end       

        function M = Ms(this, s)
            %% 
            options = optimoptions('fsolve', 'Display', 'off');
            for k = 1:length(s)
                [M(k), ~, exitflag] = fsolve(@(M) M*(1 + this.a*(M-1))^(-this.b) - exp(s(k)), 2*sign(s(k)), options);
                if exitflag ~= 1 
                    warning('Calculation of M(s) did not converge');
                end
            end  
        end       

    end
    
    methods
        function this = apd(GaindB, ka, GainBW, R, Id)
            %% Class constructors
            % Input:
            % - GaindB = gain in dB
            % - ka = impact ionization factor
            % - GainBW (optional, default = Inf) = gain bandwidth product
            % - R (optional, default = 1) = responsivity
            % - Id (optional defualt = 10 nA) = dark current (A)
            
            % Required parameters: GaindB and ka
            this.Gain = 10^(GaindB/10);
            this.ka = ka;
            
            if nargin <= 3
                this.GainBW = GainBW;
            else
                this.GainBW = Inf;
            end
                        
            if nargin <= 4
                this.R = R;
            else 
                this.R = 1;
            end
            
            if nargin <= 5
                this.Id = Id;
            else 
                this.Id = 0;
            end
        end
                           
        %% Get Methods
        function Fa = get.Fa(this) % excess noise factor
            %% Calculate Fa = Excess noise factor i.e., APD noise figure
            Fa = this.ka*this.Gain + (1 - this.ka)*(2 - 1/this.Gain); % Agrawal 4.4.18 (4th edition)
        end
               
        function GaindB = get.GaindB(this) 
            %% Calculate gain in dB
            GaindB = 10*log10(this.Gain);
        end
        
        function b = get.b(this) 
            %% Implicit relations of APD: beta = 1/(1 - ka)
            b = 1/(1-this.ka);
        end
        
        function a = get.a(this) 
            %% Implicit relations of APD: G = 1/(1 - ab)
            a =  1/this.b*(1-1/this.Gain);
        end
        
        %% Set methods
        function set.GaindB(this, GdB)
            %% Set gain in dB
            this.Gain = 10^(GdB/10); % set Gain, since GaindB is dependent
        end
        
        %% Main Methods
        function l = lambda(this, P, dt)
            %% Rate of Possion process for a given P in a interval dt
            % From Personick, "Statistics of a General Class of Avalanche Detectors With Applications to Optical Communication"
            l = (this.R*P + this.Id)*dt/this.q; 
        end
        
        function sig2 = varShot(this, Pin, Df)
            %% Shot noise variance
            % Inputs:
            % - Pin = input power of photodetector (W)
            % - Df = noise bandwidth (Hz)
            sig2 = 2*this.q*this.Gain^2*this.Fa*(this.R*Pin + this.Id)*Df; % Agrawal 4.4.17 (4th edition)
        end

        function output = detect(this, Pin, fs, noise_stats, N0)
            %% Direct detection
            % Inputs:
            % - Pin = received power (W)
            % - fs = sampling frequency (Hz)
            % - noise_stats = 'gaussian' or 'doubly-stochastic' (not
            % implemented)
            % - N0 (optional, if provided, thermal noise of psd N0 is added
            % after direct detection) = thermal noise psd
            if nargin < 5
                N0 = 0;
            end                
            
            if strcmp(noise_stats, 'gaussian')
                % Assuming Gaussian statistics               
                var_therm = N0*fs/2; % thermal noise
                
                output = this.R*this.Gain*Pin + sqrt(this.varShot(Pin, fs/2) + var_therm).*randn(size(Pin));
              
            % uses saddlepoint approximation to obtain pmf in order to generate 
            % output distributed according to that pmf
            elseif  strcmp(noise_stats, 'doubly-stochastic')  
                Plevels = unique(Pin);
                               
                output = zeros(size(Pin));
                for k = 1:length(Plevels)
                    [px, x] = this.output_pdf_saddlepoint(Plevels(k), fs, 0); % doesn't include thermal noise here
                    
                    cdf = cumtrapz(x, px);
                                                   
                    pos = (Pin == Plevels(k));
                    
                    % Sample according to pmf px
                    u = rand(sum(pos), 1); % uniformly-distributed
                    dist = abs(bsxfun(@minus, u, cdf));
                    [~, ix] = min(dist, [], 2);
                    output(pos) = x(ix); % distributed accordingly to px
                end
                
                if N0 ~= 0
                    output = output + sqrt(N0*fs/2).*randn(size(Pin)); % includes thermal noise
                end 
            else
                error('Invalid Option!')
            end
        end
        
        function Gopt = optGain_analytical(this, mpam, N0)
            %% Optimize APD gain analytically for equally-spaced levels
            % This assumes that the highest level dominates the BER
            % The optimal solution doesn't depend on RIN or extinction
            % ratio!
            % Inputs:
            % - mpam = PAM class
            % - N0 = thermal noise PSD
            b = 2*this.q*this.ka*(this.R*mpam.a(end) + this.Id)*mpam.Rs;
            d = -2*this.q*(1-this.ka)*(this.R*mpam.a(end) + this.Id)*mpam.Rs;
            e = N0*mpam.Rs;
            
            r = roots([-b 0 d e]);
            
            % Gets real root only
            if any(imag(r) == 0)
                Gopt = r(imag(r) == 0);
            else
            	% All roots are complex due to precision error. Thus, 
                % gets root with smallest imaginary part
                [~, ix] = min(abs(imag(r)));
                Gopt = real(r(ix));
            end
            
            % Eliminates negative solutions
            Gopt = Gopt(Gopt > 0);
                       
            if isempty(Gopt)
                error('Negative root found while optimizing APD gain')
            end
            
        end
        
        function Gopt = optGain(this, mpam, tx, fiber, rx, sim)
            %% Optimize APD gain: Given a certain input power calculates 
            %% the APD gain that leads to the minimum BER
                     
            Gopt = zeros(size(tx.PtxdBm));
            for k = 1:length(tx.PtxdBm)
                % Optmize gain for uniform spacing: find Gapd that minimizes the required
                % average power (Prec) to achieve a certain target SER.  
                [Gopt(k), ~, exitflag] = fminbnd(@(Gapd) this.calc_apd_ber(tx.PtxdBm(k), Gapd, mpam, tx, fiber, rx, sim), eps, min(this.GainBW/mpam.Rs, 100));    

                % Check whether solution is valid
                if exitflag ~= 1
                    warning('APD gain optimization did not converge (exitflag = %d)\n', exitflag);
                end 

                if Gopt(k) < 0
                    error('Negative root found while optimizing APD gain')
                end
            end
        end
        
        function Gopt = optimize_gain(this, mpam, tx, fiber, rx, sim)
            %% Optimize APD gain: Given a certain input power calculates the APD gain that
            %% the APD gain that leads to the minimum BER
            disp('Optimizing APD gain...')
                       
            % Optmize gain for uniform spacing: find Gapd that minimizes the required
            % average power (Prec) to achieve a certain target SER.  
            [Gopt, ~, exitflag] = fminbnd(@(Gapd) fzero(@(PtxdBm) this.calc_apd_ber(PtxdBm, Gapd, mpam, tx, fiber, rx, sim) - sim.BERtarget, -20), eps, min(this.GainBW/mpam.Rs, 100));    
            
            % Check whether solution is valid
            if exitflag ~= 1
                warning('APD gain optimization did not converge (exitflag = %d)\n', exitflag);
            end 

            if Gopt < 0
                error('Negative root found while optimizing APD gain')
            end
        end   
        
        %% Tail probabilities calculation
        % Not working properly. fsolve doesn't work as well as fzero
        function [px, shat] = tail_saddlepoint_approx(this, xthresh, P, fs, N0, tail) 
            %% Output sgnal distribution including thermal noise using the saddlepoint approximation
            % px = output sgnal pdf
            % x = current at output
            % lambda = rate of the Poisson process
            % N0 = thermal noise psd
            % fs = sampling frequency
            %% NOT FINISHED !!!
            options = optimoptions('fsolve', 'Display', 'off');
            
            % From implicit relations of APD: beta = 1/(1 - ka) and G = 1/(1 - ab)
            a = this.a;
            b = this.b;

            if P == 0
                px = 1;
                return;
            end
            
            lambda = this.lambda(P, 1/fs);

%             if strcmp(tail, 'right')
%                 sgn = 1;
%             elseif strcmp(tail, 'left')
%                 sgn = -1;
%             else
%                 error('invalid option');
%             end
           
            dt = 1/fs; % pulse width
            
            % Calculate electron number variance corresponding to thermal noise
            varTherm = (N0*fs/2)*(dt/this.q)^2;
            
            %
            nthresh = xthresh*(dt/this.q);

            % dM(e^s)/ds
            dMds = @(M) M*(1 + a*(M-1))/((1 + a*(M-1) - a*b*M)); 

            %% Calculate Saddlepoint
            % Solve value of s 
            % Can't use fzero because objective function might be complex
            % Use real(s) instead of s to force real solution
            % Solve value of M(e^s) at the saddlepoint 
            % Can't use fzero because M(e^s) might be complex
            [Mhat, ~, exitflag] = fsolve(@(M) lambda*(M*(1 + a*(M-1))/(1 + a*(M-1) - a*b*M))...
                + varTherm*(log(M) - b*log(1 + a*(M-1))) - nthresh - 1/(log(M) - b*log(1 + a*(M-1))), 1e-2, options);

            if exitflag ~= 1 % if didn't converge try again with opposite sgn
                [Mhat, ~, exitflag] = fsolve(@(M) lambda*(M*(1 + a*(M-1))/(1 + a*(M-1) - a*b*M))...
                    + varTherm*(log(M) - b*log(1 + a*(M-1))) - nthresh - 1/(log(M) - b*log(1 + a*(M-1))), -1e-2, options);
                if exitflag ~= 1
                    warning('Calculation of M at the saddlepoint did not converge');
                end
            end
            
            % From M(e^s) at the saddlepoint calculate real part of s
            shat = real(log(Mhat) - b*log(1 + a*(Mhat-1)));
            
            % Get new M(shat)
            [Mhat, ~, exitflag] = fsolve(@(M) M*(1 + a*(M-1))^(-b) - exp(shat), real(Mhat), options);
            if exitflag ~= 1 
                warning('Calculation of M at the saddlepoint did not converge');
            end          

            
            % First derivative of M(s) at the saddlepoint
            dMhat = dMds(Mhat);

            % Second derivative of M(e^(s)) evaluated at the saddlepoint
            d2Mhatds = d2Mds2(Mhat, dMhat);

            % 
            Ksp = lambda*(Mhat - 1) + 1/2*varTherm*shat^2 - shat*nthresh - log(abs(shat));
            d2Ksp = lambda*d2Mhatds + varTherm + 1/shat^2; % second derivative

            % Saddle point approximation
            px = real(exp(Ksp)./sqrt(2*pi*d2Ksp));  
                       
            % Second derivative of M(e^s)
            % M = M(e^s)
            % dM = dM(e^s)/ds
            function d2M = d2Mds2(M, dM)
                % M'' = (p'q - q'p)/q^2

                p = M.*(1 + a*(M-1));
                pprime = dM.*(1 + a*(2*M-1));
                qq = (1 + a*(M-1) - a*b*M);
                qprime = a*dM*(1 - b);

                % Second derivative of M(e^s)
                d2M = (pprime.*qq - qprime.*p)./qq.^2;
            end
        end

        function [px, x] = output_pdf_saddlepoint(this, P, fs, N0)
            %% Output sgnal distribution including thermal noise using the saddlepoint approximation
            % px = output sgnal pdf
            % x = current at output
            % lambda = rate of the Poisson process
            % N0 = thermal noise psd
            % fs = sampling frequency
            options = optimoptions('fsolve', 'Display', 'off');
            
            % From implicit relations of APD: beta = 1/(1 - ka) and G = 1/(1 - ab)
            a = this.a;
            b = this.b;

            if P == 0
                px = 1;
                x = 0;
                return;
            end
            
            % Rate of Poisson process
            lambda = this.lambda(P, 1/fs);

            dt = 1/fs; % pulse width
            
            % Calculate electron number variance corresponding to thermal noise
            varTherm = (N0*fs/2)*(dt/this.q)^2;

            % dM(e^s)/ds
            dMds = @(M) M*(1 + a*(M-1))/((1 + a*(M-1) - a*b*M));

            % Uses gaussian appproximation to estimate number of points sufficient to obtain great part of the pdf
            % this.Ptail is the probability of the tails not spanned by the
            % calculated pdf
            nmean = lambda*this.Gain;
            nvar = this.Gain^2*this.Fa*lambda + varTherm;
            npos = ceil(sqrt(nvar)*qfuncinv(this.Ptail));
            N = max(0, nmean-npos):(nmean+npos);

            %% Calculate Saddlepoint
            px = zeros(size(N));
            for k = 1:length(N)
                n = N(k);
                
               % Solve value of M(e^s) at the saddlepoint 
                % Can't use fzero because M(e^s) might be complex
                [Mhat, ~, exitflag] = fsolve(@(M) lambda*(M*(1 + a*(M-1))/(1 + a*(M-1) - a*b*M)) + varTherm*(log(M) - b*log(1 + a*(M-1))) - n, 1, options);

                if exitflag ~= 1 % if didn't converge try again with opposite sgn
                    [Mhat, ~, exitflag] = fsolve(@(M) lambda*(M*(1 + a*(M-1))/(1 + a*(M-1) - a*b*M)) + varTherm*(log(M) - b*log(1 + a*(M-1))) - n, -1, options);
                    if exitflag ~= 1
                        warning('Calculation of M at the saddlepoint did not converge');
                        continue
                    end
                end
               
                % From M(e^s) at the saddlepoint calculate real part of s
                shat = real(log(Mhat) - b*log(1 + a*(Mhat-1)));
                
%                 Mhat = this.Ms(shat);

                % Get new M(shat)
                [Mhat, ~, exitflag] = fsolve(@(M) M*(1 + a*(M-1))^(-b) - exp(shat), real(Mhat), options);
                if exitflag ~= 1 
                    warning('Calculation of M at the saddlepoint did not converge');
                end  
                
                % First derivative of M(s) at the saddlepoint
                dMhat = dMds(Mhat);

                % Second derivative of M(e^(s)) evaluated at the saddlepoint
                d2Mhatds = d2Mds2(Mhat, dMhat);

                % 
                Ksp = lambda*(Mhat - 1) + 1/2*varTherm*shat^2 - shat*n;
                d2Ksp = lambda*d2Mhatds + varTherm; % second derivative

                % Saddle point approximation
                px(k) = real(exp(Ksp)./sqrt(2*pi*d2Ksp));  
            end

            x = N*(this.q/dt);
            px = px*(dt/this.q);
            
            intpx = trapz(x, px);
            
            if intpx < 1 - 2*this.Ptail
                warning(sprintf('output_pdf_saddlepoint: pdf accounts only for %g of probability, %g was expected', intpx, 1 - 2*this.Ptail));
            end
            
            % renormalized pdf
            px = px/intpx;
                                    
            % Second derivative of M(e^s)
            % M = M(e^s)
            % dM = dM(e^s)/ds
            function d2M = d2Mds2(M, dM)
                % M'' = (p'q - q'p)/q^2

                p = M.*(1 + a*(M-1));
                pprime = dM.*(1 + a*(2*M-1));
                qq = (1 + a*(M-1) - a*b*M);
                qprime = a*dM*(1 - b);

                % Second derivative of M(e^s)
                d2M = (pprime.*qq - qprime.*p)./qq.^2;
            end            
        end
        
        % Calculate noise pdf for a sgnal levels Plevels with duration dt.
        % The Gaussian approximation is compared with the distribution 
        % calculated using the saddlepoint approximation
        function lpdf = levels_pdf(this, Plevels, fs)           
            % Struct of levels pdf: 
            lpdf = struct('p', 0, 'p_gauss', 0, 'I', 0,... % p(I) = true pdf, p_gauss(I) = pdf under Gaussian approximation
                'mean', 0, 'mean_gauss', 0,... % true mean and mean under Gaussian approximation
                'var', 0, 'var_gauss', num2cell(zeros(size(Plevels)))); % true variance and variance under Gaussian approximation
            
            for k = 1:length(Plevels)                  
                
                if Plevels(k) == 0
                    continue
                end
                
                [lpdf(k).p, lpdf(k).I] = this.output_pdf_saddlepoint(Plevels(k), fs, 0);
                                               
                lpdf(k).mean = trapz(lpdf(k).I, lpdf(k).I.*lpdf(k).p);
                lpdf(k).mean_gauss = Plevels(k)*this.Gain;
                lpdf(k).var = trapz(lpdf(k).I, lpdf(k).I.^2.*lpdf(k).p) - lpdf(k).mean.^2;
                lpdf(k).var_gauss = this.varShot(Plevels(k), fs/2);
                
                lpdf(k).p_gauss = pdf('normal', lpdf(k).I, lpdf(k).mean_gauss, sqrt(lpdf(k).var_gauss));
            end
        end
        
        %% Output sgnal pmf (without thermal noise)
        % pn = probability of observing n electrons at the output
        % lambda = rate of the Poisson process
        function pn = output_pmf(this, lambda)          
            pn = exp(-lambda); % n = 0;
            
            psum = pn;
            k = 0; % current iteration   
            r = 0;
            mr1 = this.calc_mr(r+1);
            while psum  < this.cdf_accuracy && k < this.Niterations              
                pn(k+2) = lambda/(k+1)*sum((r+1).*mr1.*fliplr(pn(r+1)));
                
                psum = psum + pn(k+2);
                
                k = k + 1;
                
                r = [r k];
                
                mr1 = [mr1 calc_mr(k+1)];
            end
            
            if k >= this.Niterations
                warning(sprintf('output_pmf(this, lambda): max number of iterations exceeded. pmf accounts only for %f of probability', psum));
            end
            
            % Calculate mr given in C. Helstrom "Computattion of Output
            % Electron Distributions in Avalanche Photodiodes"
            function mr = calc_mr(r)

                P2 = (r-1)*log(this.a);
                P3 = (r*(this.b-1)+1)*log(1 - this.a);
                P4 = sum(log(1:r)); % P4 = log(factorial(r));

                if r < 100 % calculate exactly
                    P1 = log(gamma(this.b*r + 1));
                    P5 = log(gamma(r*(this.b-1) + 2));
                else % use Stirling's formula for the factorial and Gamma functions
                    stirling_approx = @(z) log(sqrt(2*pi/z)) + z*log(z/exp(1));
                    P1 = stirling_approx(this.b*r + 1);
                    P5 = stirling_approx(r*(this.b-1) + 2);                
                end      

                P = P1 + P2 + P3 - P4 - P5;

                mr = exp(P);
            end
        end
        
        
    end
end
    


% 
%   %% Random Gain distribution using the saddle point approximation
%         %% Does not include thermal noise
%         % pn = probability of observing n electrons at the output
%         % n = number of electrons at the output
%         % lambda = rate of the Poisson process
%         % Does not include thermal noise
%         function [pn, n] = output_pmf_saddlepoint(this, lambda)
%             a = this.a;
%             b = this.b;
%             
%             if lambda == 0
%                 pn = 1;
%                 n = 0;
%                 return;
%             end
%             
%             % Estimate number of points sufficient to obtain great part of the pmf
%             nmean = lambda*this.Gain;
%             nvar = this.Gain^2*this.Fa*lambda;
%             npos = fzero(@(x) qfunc(x/sqrt(nvar)) - this.Ptail, 5*sqrt(nvar));
%             n = max(0, nmean-npos):(nmean+npos);
% %             n = 0:(lambda*this.Gain*5);
%             
%             %% Calculate Saddle-point
%             % based on the derivation by C. W. Helstrom in "Computation of
%             % Output Electron Distributions in Avalanche Photodiodes"
%             tau = n + 1;
%             gamma = lambda*(1-a) + a*(b - 1)*tau;
%             
%             % probability generating function of p(n|1) evaluated at the
%             % saddle point
%             Msp = (sqrt(gamma.^2 + 4*a*(1-a)*lambda*tau) - gamma)/(2*a*lambda);
%             
%             % z at the saddle point (should be real)
%             zsp = Msp.*(1 + a*(Msp-1)).^(-b);
%             
%             % First and second derivative of M(z) evaluated at the saddle point
%             % M' = p/q
%             % M'' = (p'q - q'p)/q^2
%             
%             M = Msp; 
%             dM = M.*(1 + a*(M-1))./(zsp.*(1 + a*(M - 1) - a*b*M));
%             
%             p = M.*(1 + a*(M-1));
%             pprime = dM.*(1 + a*(2*M-1));
%             qq = zsp.*(1 + a*(M-1) - a*b*M);
%             qprime = 1 + a*(M + zsp.*dM - 1) - a*b*(M + zsp.*dM);
%             
%             % Second derivative of M(z) evaluated at the saddle point
%             ddM = (pprime.*qq - qprime.*p)./qq.^2;
%             
%             % Phase function (i.e., Ksp = lambda(M(z)-1) - nln(z)
%             Ksp = lambda*(M -1) - n.*log(zsp);
%             ddKsp = lambda*ddM + n./zsp.^2; % second derivative
%             
%             % Saddle point approximation
%             pn = exp(Ksp)./sqrt(2*pi*ddKsp);  
%         end




            