# ---------------------- #
# Jupyter notebook setup #
# ---------------------- #

type JupyterDisplay <: AbstractPlotlyDisplay
    divid::Base.Random.UUID
    displayed::Bool
    cond::Condition  # for getting data back from js
end

typealias JupyterPlot SyncPlot{JupyterDisplay}

JupyterDisplay(p::Plot) = JupyterDisplay(p.divid, false, Condition())
JupyterPlot(p::Plot) = JupyterPlot(p, JupyterDisplay(p))

fork(jp::JupyterPlot) = JupyterPlot(fork(jp.plot))

const _jupyter_js_loaded = [false]
js_loaded(::JupyterDisplay) = _jupyter_js_loaded[1]
js_loaded(::Type{JupyterDisplay}) = _jupyter_js_loaded[1]

function html_body(p::JupyterPlot)
    """
    <div id="$(p.view.divid)" class="plotly-graph-div"></div>

    <script>
        window.PLOTLYENV=window.PLOTLYENV || {};
        window.PLOTLYENV.BASE_URL="https://plot.ly";
        require(['plotly'], function(Plotly) {
            $(script_content(p.plot))
        });
     </script>
    """
end

# if we're in IJulia call setup the notebook js interop
if isdefined(Main, :IJulia) && Main.IJulia.inited
    # borrowed from https://github.com/plotly/plotly.py/blob/2594076e29584ede2d09f2aa40a8a195b3f3fc66/plotly/offline/offline.py#L64-L71
    # and https://github.com/JuliaLang/Interact.jl/blob/cc5f4cfd34687000bc6bc70f0513eaded1a7c950/src/IJulia/setup.jl#L15
    if !js_loaded(JupyterDisplay)
        const _ijulia_js = readall(joinpath(dirname(@__FILE__), "ijulia.js"))
        display("text/html", """
        <script charset="utf-8" type='text/javascript'>
            $(_ijulia_js)
        </script>
         <script charset="utf-8" type='text/javascript'>
             define('plotly', function(require, exports, module) {
                 $(open(readall, _js_path, "r"))
             });
             require(['plotly'], function(Plotly) {
                 window.Plotly = Plotly;
             });
         </script>
         <p>Plotly javascript loaded.</p>
         """)
        _jupyter_js_loaded[1] = true
    end

    @eval begin
        import IJulia
        import IJulia: @vprintln
        import IJulia.CommManager: Comm, send_comm
    end

    # set up the comms we will use to send js messages to be executed
    const _ijulia_eval_comm = Comm(:plotlyjs_eval)
    const _ijulia_return_comms = Dict{Base.Random.UUID,Comm}()

    function get_comm(jd::JupyterDisplay)
        if haskey(_ijulia_return_comms, jd.divid)
            return _ijulia_return_comms[jd.divid]
        else
            comm = Comm(:plotlyjs_return)

            function handle_comm_msg(msg)
                open(joinpath(ENV["HOME"], "from_plotly_comm2.txt"), "w") do f
                    println(f, """This is msg:\n$(msg)\n\n\n""")
                    println(f, """This is msg.content:\n$(msg.content)\n\n\n""")
                    println(f, """This is msg.content["data"]:\n$(msg.content["data"])\n\n\n""")
                    # println(f, "I am in on_msg from plotly")
                end

                if haskey(msg.content, "data")
                    open(joinpath(ENV["HOME"], "from_plotly_comm2.txt"), "a") do f
                        println(f, "passed the if haskey check\n\n")
                    end
                    action = get(msg.content["data"], "action", "")

                    open(joinpath(ENV["HOME"], "from_plotly_comm2.txt"), "a") do f
                        println(f, "Got action: $(action)\n\n")
                    end
                    if action == "plotlyjs_ret_val"

                        open(joinpath(ENV["HOME"], "from_plotly_comm2.txt"), "a") do f
                            println(f, "Passed the if action == check\n\n")
                        end
                        @show val = msg.content["data"]["ret"]

                        open(joinpath(ENV["HOME"], "from_plotly_comm2.txt"), "a") do f
                            println(f, "Got val: $(val)\n\n")
                        end
                        # Main.IJulia.@vprintln("\n\n\n\n\n\n\nWe got a val! $val\n\n\n\n\n\n\n")
                        # now that we have the value, we can notify waiting
                        # tasks that the return value is ready
                        notify(jd.cond, val)
                    end
                end
            end

            comm.on_msg = handle_comm_msg

            _ijulia_return_comms[jd.divid] = comm
            return comm
        end
    end

    IJulia.display_dict(p::Plot) =
        Dict("text/plain" => sprint(writemime, "text/plain", p))

    function IJulia.display_dict(p::JupyterPlot)
        if p.view.displayed
            Dict()
        else
            p.view.displayed = true
            Dict("text/html" => html_body(p))
        end
    end

end

function _call_js_return(jd::JupyterDisplay, code)
    Main.IJulia.CommManager.send_comm(get_comm(jd), Dict{Any,Any}("code" => code))  # will trigger `on_msg`
    return wait(jd.cond)  # wait for `notify` within `comm.on_msg` to be called
end

_call_js(jd::JupyterDisplay, code) =
    send_comm(_ijulia_eval_comm, Dict("code" => code))

## API Methods for JupyterDisplay
_the_div_js(jd::JupyterDisplay) = "document.getElementById('$(jd.divid)')"
_the_div_js(jp::JupyterPlot) = _the_div_js(jp.view)

function _img_data(jp::JupyterPlot, format::ASCIIString)
    _formats = ["png", "jpeg", "webp", "svg"]
    if !(format in _formats)
        error("Unsupported format $format, must be one of $_formats")
    end

    if format == "svg"
        return svg_data(jp)
    end

    code =  """
    ev = Plotly.Snapshot.toImage($(_the_div_js(jp)), {format: '$(format)'});
    new Promise(function(resolve) {ev.once("success", resolve)});
    """
    _call_js_return(jp.view, code)
end

function svg_data(jp::JupyterPlot, format="png")
    code =  "Plotly.Snapshot.toSVG($(_the_div_js(jp)), '$(format)')"
    _call_js_return(jp.view, code)
end

function _call_plotlyjs(jd::JupyterDisplay, func::AbstractString, args...)
    arg_str = length(args) > 0 ? string(",", join(map(json, args), ", ")) : ""
    code = "Plotly.$func($(_the_div_js(jd)) $arg_str)"
    jd.displayed && _call_js(jd, code)
    nothing
end

# Methods from javascript API
relayout!(jd::JupyterDisplay, update::Associative=Dict(); kwargs...) =
    _call_plotlyjs(jd, "relayout", merge(update, prep_kwargs(kwargs)))

restyle!(jd::JupyterDisplay, ind::Int, update::Associative=Dict(); kwargs...) =
    _call_plotlyjs(jd, "restyle", merge(update, prep_kwargs(kwargs)), ind-1)

function restyle!(jd::JupyterDisplay, inds::AbstractVector{Int},
                  update::Associative=Dict();  kwargs...)
    _call_plotlyjs(jd, "restyle", merge(update, prep_kwargs(kwargs)), inds-1)
end

restyle!(jd::JupyterDisplay, update::Associative=Dict(); kwargs...) =
    _call_plotlyjs(jd, "restyle", merge(update, prep_kwargs(kwargs)))

addtraces!(jd::JupyterDisplay, traces::AbstractTrace...) =
    _call_plotlyjs(jd, "addTraces", traces)

addtraces!(jd::JupyterDisplay, where::Int, traces::AbstractTrace...) =
    _call_plotlyjs(jd, "addTraces", traces, where-1)

deletetraces!(jd::JupyterDisplay, traces::Int...) =
    _call_plotlyjs(jd, "deleteTraces", collect(traces)-1)

movetraces!(jd::JupyterDisplay, to_end::Int...) =
    _call_plotlyjs(jd, "moveTraces", collect(to_end)-1)

movetraces!(jd::JupyterDisplay, src::AbstractVector{Int}, dest::AbstractVector{Int}) =
    _call_plotlyjs(jd, "moveTraces", src-1, dest-1)

redraw!(jd::JupyterDisplay) = _call_plotlyjs(jd, "redraw")

# unexported (by plotly.js) api methods
extendtraces!(jd::JupyterDisplay, update::Associative=Dict(),
              indices::Vector{Int}=[1], maxpoints=-1;) =
    _call_plotlyjs(jd, "extendTraces", update, indices-1, maxpoints)

prependtraces!(jd::JupyterDisplay, update::Associative=Dict(),
               indices::Vector{Int}=[1], maxpoints=-1;) =
    _call_plotlyjs(jd, "prependTraces", update, indices-1, maxpoints)
