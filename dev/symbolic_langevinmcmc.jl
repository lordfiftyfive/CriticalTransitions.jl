include("../src/StochSystem.jl")

#sys = fhn_ϵσ(0.1,0.1)

# Central finite difference, second derivative
function central(f, idx, dz)
    (f[idx+1] - f[idx-1])/(2*dz)
end

function central2(f, idx, dz)
    (f[idx+1] - 2f[idx] + f[idx-1])/(dz^2)
end

function langevinmcmc_spde(u, p, t)
    
    ## in the parameters vector we need:
    # the dimension of the system, dim
    # the noise strength of the system, σ
    # the (invertible) transport matrix, Q
    # the physical time step, Δz
    # the state variables in symbolic form, x_{i=1}^dim, state_vars
    # the jacobian of the drift, jacobian
    # the penultimate term as a callable function, grad_dot_term
    # the final term as a function, grad_div_term

    dim, σ, Q, Δz, state_vars, jacobian, grad_dot_term, grad_div_term = p[1]
    
    N = Int(length(u)/dim); # the number of components across the path
    du = zeros(length(u)); # a dummy storage for the derivatives

    for ii ∈ 2:N-1
        
        dzxii = [central(u[(jj-1)*N+1:jj*N], ii, Δz) for jj ∈ 1:dim]; # the derivative ∂x/∂z at physical time z = (ii-1)*Δz 
        dzzxii = [central2(u[(jj-1)*N+1:jj*N], ii, Δz) for jj ∈ 1:dim]; # the derivative ∂^2x/∂z^2 at physical time z = ii*Δz
        xii = [u[(jj-1)*N+ii] for jj ∈ 1:dim]; # the state variable state_vars at z = (ii-1)*Δz

        J = substitute.(jacobian, (Dict(zip(state_vars,xii)),)); # the jacobian evaluated at xii 
        Jxii = Symbolics.value.(J); # making this usable
        f = substitute.(grad_dot_term, (Dict(zip(state_vars,xii)),));
        fxii = Symbolics.value.(f);
        g = substitute.(grad_div_term, (Dict(zip(state_vars,xii)),));
        gxii = Symbolics.value.(g);

        du[[(jj-1)*N+ii for jj ∈ 1:dim]] = inv(Q)*dzzxii - (inv(Q)*Jxii - Jxii'*inv(Q))*dzxii - (1/2)*fxii - (σ^2/2)*gxii;

    end

    SVector{length(u)}(du)

end

function symbolise_spde(sys::StochSystem)

    # creating symbolic state variables
    state_vars = @eval @variables $([Symbol("x$i") for i=1:sys.dim]...);

    # next, the deterministic drift of the system in symbolic form
    drift = sys.f(state_vars,[sys.pf],@variables t)

    # next, the jacobian of the drift in symbolic form
    jacobian = Symbolics.jacobian(drift,state_vars);

    # next, the penultimate deterministic term in the LangevinMCMC SPDE
    grad_dot_term = Symbolics.gradient(dot(drift, inv(sys.Σ)*drift), state_vars);
    
    # finally, the last deterministic term in the LangevinMCMC SPDE
    grad_div_term = Symbolics.gradient(tr(jacobian), state_vars); # since the divergence is purely the trace of the jacobian
    
    return state_vars, jacobian, grad_dot_term, grad_div_term

end

function jacobian(sys::StochSystem)
    # creating symbolic state variables
    state_vars = @eval @variables $([Symbol("x$i") for i=1:sys.dim]...);

    # next, the deterministic drift of the system in symbolic form        
    drift = sys.f(state_vars,[sys.pf],@variables t);
    
    # next, the jacobian of the drift in symbolic form
    jacobian = Symbolics.jacobian(drift,state_vars)

end

function jacobian(sys:StochSystem, x::State)

    # loading the Jacobian in symbolic form
    jacobian = jacobian(sys);

    # calling the Jacobian at the state value x
    state_vars = @eval @variables $([Symbol("x$i") for i=1:sys.dim]...);
    J = substitute.(jacobian, (Dict(zip(state_vars,x)),)); # the jacobian evaluated at x
    Jx = Symbolics.value.(J);

    return jacobian, Jx

end
    


function langevinmcmc(sys::StochSystem, init;    
    T = 15,         # physical end time
    tmax = 250.0,   # virtual end time
    Δt = 1e-3,      # virtual time step
    )

    N = size(init, 2); # the number of columns in the initial condition gives the number of components of the path 
    Δz = T/(N-1); # the physical time step
    t = range(0, T; length = N); # the physical time range

    Nstep = round(Int64, tmax/Δt); # the number of mcmc iterations

    paths = zeros(Nstep+1, sys.dim, N); # three-dimensional array to store the paths
    paths[1,:,:] = init; # storing the initial condition
    t = 0; # the current virtual time value 

    # defining the number of functions used in langevin mcmc 

    state_vars, jacobian, grad_dot_term, grad_div_term = symbolise_spde(sys);

    p = [sys.dim, sys.σ, sys.Σ, Δz, state_vars, jacobian, grad_dot_term, grad_div_term]; # langevinmcmcSPDE parameters 

    for it ∈ 1:Nstep

        update = langevinmcmc_spde(vec(paths[it,:,:]'), [p], t); # this gives the virtual-time derivatives for all components on the current path

        # we need to split update (dim*N × 1) into a dim × N matrix
        update_mod = zeros(sys.dim, N)
        for jj ∈ 1:sys.dim
            update_mod[jj,:] = update[(jj-1)*N+1:jj*N];
        end 

        paths[it+1,:,:] = paths[it,:,:] .+ (Δt * update_mod .+ sys.σ * √(2*Δt/Δz)*randn(sys.dim,N)); # the Euler-Maruyama step 
        
        # reseting the fixed end points
        for jj ∈ 1:sys.dim
            paths[it+1,jj,[1,end]] = paths[it,jj,[1,end]]
        end

        t += Δt;

    end

    paths

end