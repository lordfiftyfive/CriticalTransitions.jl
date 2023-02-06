include("../src/StochSystem.jl")
include("../src/utils.jl")
include("../src/io/io.jl")
include("../src/trajectories/simulation.jl")

function residence_time(sys::StochSystem, x_i::State, x_f::State;
    rad_i=0.1,
    rad_f=0.1,
    dt=0.01,
    tmax=1e3,
    solver=EM(),
    progress=true,
    rad_dims=1:sys.dim, 
    kwargs...)

    condition(u,t,integrator) = subnorm(u - x_f; directions=rad_dims) < rad_f
    affect!(integrator) = terminate!(integrator)
    cb_ball = DiscreteCallback(condition, affect!)

    restime = simulate(sys, x_i, dt=dt, tmax=tmax, solver=solver, callback=cb_ball, progress=progress, kwargs...).t[end]

    success = true
    if restime == tmax
        success = false
    end

    restime, success

end

function residence_times(sys::StochSystem, x_i::State, x_f::State, N=1;
    rad_i=0.1,
    rad_f=0.1,
    dt=0.01,
    tmax=1e3,
    solver=EM(),
    progress=true,
    rad_dims=1:sys.dim,
    Nmax = 1000,
    savefile = nothing,
    showprogress::Bool = true,
    kwargs...)

    times::Vector, idx::Vector{Int64}, r_idx = zeros(Float64,N), zeros(Int64, N), 0.

    i = Threads.Atomic{Int}(0); # assign a race-free counter for the number of transitions
    j = Threads.Atomic{Int}(0); # assign a race-free counter for the number of non-transitions

    iterator = showprogress ? tqdm(1:Nmax) : 1:Nmax

    Threads.@threads for jj ∈ iterator
    
        restime, success = residence_time(sys, x_i, x_f;
                rad_i, rad_f, rad_dims, dt, tmax,
                solver, progress, kwargs...)
        
        if success && i[] < N
            
            Threads.atomic_add!(i, 1); # safely add 1 to the counter

            if showprogress
                print("\rStatus: $(length(findall(idx.!==0))+1)/$(N) transitions complete.")
            end

            if savefile == nothing
                times[i[]] = restime;
                #push!(times, restime);
            else # store or save in .jld2 file
                write(savefile, "times/times "*string(jj), restime)
            end
        
            idx[i[]] = jj;

        elseif i[] ≥ N
            break
        else
            Threads.atomic_add!(j, 1); # safely add 1 to the counter
            r_idx += 1 
        end

    end

    times = times[findall(v->v!=0.,times)]; 

    idx = times[findall(v->v!=0.,idx)];

    times, idx, r_idx

end

function residence_time2(sys::StochSystem, x_i::State, x_f1::State, x_f2::State;
    rad_i=0.1,
    rad_f=0.1,
    dt=0.01,
    tmax=1e3,
    solver=EM(),
    progress=true,
    rad_dims=1:sys.dim, 
    kwargs...)

    condition(u,t,integrator) = subnorm(u - x_f1; directions=rad_dims) < rad_f || subnorm(u - x_f2; directions=rad_dims) < rad_f
    affect!(integrator) = terminate!(integrator)
    cb_ball = DiscreteCallback(condition, affect!)

    sim = simulate(sys, x_i, dt=dt, tmax=tmax, solver=solver, callback=cb_ball, progress=progress, kwargs...)

    restime, desination = sim.t[end], sim.u[:,end]; 

    success = true
    if restime == tmax
        success = false
    end

    new_state = 0; # means the system did not transition to a new attracting state in the simulation
    if success # i.e. the simulation ended prematurely (and hence transitioned)
        if subnorm(destination - x_f1; directions=rad_dims) < rad_f    
            new_state = 1; # means the system transitioned to the new attracting state x_f1
        else # we must therefore have that subnorm(destination - x_f1; directions=rad_dims) < rad_f 
            new_state = 2;      
        end
    end

    restime, success, new_state

end

function residence_times2(sys::StochSystem, x_i::State, x_f1::State, x_f2::State, N=1;
    rad_i=0.1,
    rad_f=0.1,
    dt=0.01,
    tmax=1e3,
    solver=EM(),
    progress=true,
    rad_dims=1:sys.dim,
    Nmax = 1000,
    savefile = nothing,
    showprogress::Bool = true,
    kwargs...)

    times::Vector, idx::Array{Float64}, r_idx = zeros(Int64,N), zeros(Float64, N,2), 0.

    i = Threads.Atomic{Int}(0); # assign a race-free counter for the number of transitions
    j = Threads.Atomic{Int}(0); # assign a race-free counter for the number of non-transitions

    iterator = showprogress ? tqdm(1:Nmax) : 1:Nmax

    Threads.@threads for jj ∈ iterator
    
        restime, success, new_state = residence_time2(sys, x_i, x_f1, x_f2;
                rad_i, rad_f, rad_dims, dt, tmax,
                solver, progress, kwargs...)
        
        if success && i[] < N
            
            Threads.atomic_add!(i, 1); # safely add 1 to the counter

            if showprogress
                print("\rStatus: $(length(findall(idx.!==0))+1)/$(N) transitions complete.")
            end

            if savefile == nothing
                times[i[]] = restime;
                #push!(times, restime);
            else # store or save in .jld2 file
                write(savefile, "times/times "*string(jj), restime)
            end
        
            idx[i[]] = [jj,new_state];

        elseif i[] ≥ N
            break
        else
            Threads.atomic_add!(j, 1); # safely add 1 to the counter
            r_idx += 1 
        end

    end

    times = times[findall(v->v!=0.,times)]; 

    idx = times[findall(v->v!=0.,idx)];

    times, idx, r_idx

end

function get_res_times(restimes::Dict, idx, sample_size::Int64, no_of_samples::Int64)

    rtimes = [restimes["transition $(i)"] for i ∈ idx];
    mtimes = [mean(rtimes[(ii-1)*sample_size+1:ii*sample_size]) for ii ∈ 1:no_of_samples];

    rtimes, mtimes

end

struct ResTimes
    data_dimensions::String
    res_times::Dict
end

struct temporal
    system_info::String
    data_info::String
    run_info::String
    success_fraction::Float64
    path_numbers::Vector
    data::ResTimes
end

function runandsavetimes(sys::StochSystem, systag::String, fixedpoints_dims, N; 
    R2L = true,
    rad_i = 0.1,
    rad_f = 0.1,
    dt=0.01,
    tmax=1e3,
    Nmax=1000,
    solver=EM(), 
    comp = "linux",
    showprogress = true,
    save = true)

    # the direction of transition
    if R2L
        direction = "R2L"
    else
        direction = "L2R"
    end

    # file name and save name directory
    if comp == "linux"
        filepath = "/home/ryand/Documents/Oldenburg/Data/";
    elseif comp == "windows"
        filepath = "C:\\Users\\ryand\\Documents\\Oldenburg\\Data\\"
    elseif comp == "tethys"
        filepath = "/home/ryand/Data/"
    end

    filename = "$(systag)_$(direction)_σ$(sys.σ)_N$(N)";
    time = Dates.now();
    savename = filepath*Dates.format(time, "ddmmyy")*"_"*filename*".jld2"
    #savename = "/ryand/home/Documents/Oldenburg/Data/$(systag)_$(direction)_σ$(sys.σ)_N$(N)"

    # compute and define fixed points
    fps = fixedpoints(sys, fixedpoints_dims[1:2], fixedpoints_dims[3:4]);
    sfps = fps[1][fps[3]];
    R = sfps[findmax(sfps[:,1])[2],:];
    L = sfps[findmin(sfps[:,1])[2],:];

    # transitioning from right to left or left to right?
    if ~R2L
        R, L = L, R
    end
    
    # I/O info
    info0 = "Attempting $(N) transition samples of $(systag) system with noise intensity $(sys.σ)."
    info1 = "Start/end conditions:\n Initial state: $(R), ball radius $(rad_i)\n Final state: $(L), ball radius $(rad_f)"
    info2 = "Run details:\n time step dt=$(dt), maximum duration tmax=$(tmax), solver=$(string(solver))"
    info3 = "Dataset info:\n paths: transition path arrays of dimension (state × time), where a state is a vector [u,v]\n times: arrays of time values of the corresponding paths"

    println(info0*"\n--> "*info1*"\n--> "*info2)
    println("--> Saving data to $(filepath).")

    # create components of the data file struct
    data_dimensions = "[time (since beginning of simulation)], arbitrary units";
    system_info = sys_string(sys, verbose=true);
    data_info = info3;

    # call transitions function 
    tstart = now();
    times, idx, reject = residence_times(sys, R, L, N;
    rad_i, rad_f, dt, tmax, solver, Nmax, showprogress, savefile=nothing);

    # finalise run
    runtime = canonicalize(Dates.CompoundPeriod(Millisecond(now()-tstart)));
    # run statistics
    run_info = info0*"\n"*info1*"\n"*info2*"\nRuntime: $(runtime)";
    success_fraction = length(idx)/(reject+length(idx));
    path_numbers = sort(idx);

    # create realisations of the structs
    data = ResTimes(data_dimensions, Dict(["transition $(i)" for i ∈ idx] .=> times));

    everything = temporal(system_info, data_info, run_info, success_fraction, path_numbers, data);
    
    if save
        safesave(savename, struct2dict(everything))
    end

    println("... Done! Closing file. Run took $(runtime).")
    println("... Summary: $(length(idx))/$(reject+length(idx)) samples transitioned.")

end