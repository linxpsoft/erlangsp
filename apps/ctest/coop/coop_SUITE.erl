-module(coop_SUITE).

-include("../../erlangsp/include/license_and_copyright.hrl").
-include_lib("common_test/include/ct.hrl").
-include("../../coop/include/coop_dag.hrl").

%% Suite functions
-export([all/0, init_per_suite/1, end_per_suite/1]).

%% Pipeline and fanout tests
-export([pipeline_flow/1, pipeline_failure/1, pipeline/1,
         fanout_failure/1, fanout_flow/1]).
-export([init/1, plus2/2, times3/2, minus5/2]).

%% Test procs for validating process message output
-export([receive_pipe_results/0]).
 
all() -> [pipeline_flow, pipeline_failure, pipeline, 
          fanout_failure, fanout_flow].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.


%%----------------------------------------------------------------------
%% Pipeline patterns
%%----------------------------------------------------------------------
init([f1]) -> f1;
init([f2]) -> f2;
init([f3]) -> f3.

%% Init state and looping state are unused, but checked placeholders.
plus2(f1, Num)  -> {f1, Num+2}.
times3(f2, Num) -> {f2, Num*3}.
minus5(f3, Num) -> {f3, Num-5}.
    
example_pipeline_fns() ->
    %% Pipeline => 3 * (X+2) - 5
    F1_Init = {?MODULE, init, [f1]},
    F2_Init = {?MODULE, init, [f2]},
    F3_Init = {?MODULE, init, [f3]},

    F1_Task = {?MODULE, plus2},
    F2_Task = {?MODULE, times3},
    F3_Task = {?MODULE, minus5},

    F1_Node_Fn = #coop_node_fn{init=F1_Init, task=F1_Task},
    F2_Node_Fn = #coop_node_fn{init=F2_Init, task=F2_Task},
    F3_Node_Fn = #coop_node_fn{init=F3_Init, task=F3_Task},

    [
     #coop_dag_node{name=a, label=F1_Node_Fn},
     #coop_dag_node{name=b, label=F2_Node_Fn},
     #coop_dag_node{name=c, label=F3_Node_Fn}
    ].


pipeline_flow(_Config) ->
    Pipe_Stages = example_pipeline_fns(),
    Pipeline = coop_flow:pipeline(Pipe_Stages),
    Pipe_Stats = digraph:info(Pipeline),
    acyclic = proplists:get_value(cyclicity, Pipe_Stats),

    %% Check a -> b -> c...
    3 = digraph:no_vertices(Pipeline),
    2 = digraph:no_edges(Pipeline),

    %% Unidirectional flow...
    [a,b,c] = digraph:get_path(Pipeline, a, c),
    false   = digraph:get_path(Pipeline, c, a),
    
    %% Check graph vertices.
    3 = length(digraph:vertices(Pipeline)),
    [A, B, C] = [{N, L} || #coop_dag_node{name=N, label=L} <- Pipe_Stages],
    A = digraph:vertex(Pipeline, a),
    B = digraph:vertex(Pipeline, b),
    C = digraph:vertex(Pipeline, c).


pipeline(_Config) ->
    Pid = spawn_link(?MODULE, receive_pipe_results, []),
    Pipe_Stages = example_pipeline_fns(),
    Kill_Switch = coop_kill_link_rcv:make_kill_switch(),
    {First_Stage_Node, _Template_Graph, Coops_Graph} = coop:pipeline(Kill_Switch, Pipe_Stages, Pid),
    Pipe_Stats = digraph:info(Coops_Graph),
    acyclic = proplists:get_value(cyclicity, Pipe_Stats),
    coop:relay_data(First_Stage_Node, 7),
    timer:sleep(100),
    ok = fetch_results(Pid).

pipeline_failure(_Config) ->
    try coop_flow:pipeline(a)
    catch error:function_clause -> ok
    end,

    try coop_flow:pipeline([a])
    catch error:function_clause -> ok
    end.
    

fetch_results(Pid) ->
    Pid ! {fetch, self()},
    receive Any -> Any
    after 3000 -> timeout_waiting
    end.
    
receive_pipe_results() ->
    receive
        3 * (7+2) - 5 -> hold_results(ok);
        Other ->  hold_results({fail, Other})
    after 3000 -> hold_results(timeout)
    end.

hold_results(Results) ->
    receive
        {fetch, From} -> From ! Results
    after 3000 -> timeout
    end.


%%----------------------------------------------------------------------
%% Fanout patterns
%%----------------------------------------------------------------------
check_fanout_vertex(Graph, #coop_dag_node{label=Label}, inbound = Name, InDegree, OutDegree) ->
    {Name, Label} = digraph:vertex(Graph, Name),
    InDegree   = digraph:in_degree(Graph, Name),
    OutDegree  = digraph:out_degree(Graph, Name),
    InDegree   = length(digraph:in_neighbours(Graph, Name)),
    OutDegree  = length([V || V <- digraph:out_neighbours(Graph, Name)]);
check_fanout_vertex(Graph, Pid, outbound = Name, InDegree, OutDegree) ->
    {Name, Pid} = digraph:vertex(Graph, Name),
    InDegree    = digraph:in_degree(Graph, Name),
    OutDegree   = digraph:out_degree(Graph, Name),
    InDegree    = length([V || V <- digraph:in_neighbours(Graph, Name)]),
    OutDegree   = length(digraph:out_neighbours(Graph, Name));
check_fanout_vertex(Graph, _N, {Name, _Fn}, 1, 1) ->    
    {Name, #coop_node_fn{}} = digraph:vertex(Graph, Name),
    [inbound] =  digraph:in_neighbours(Graph, Name),
    [outbound] = digraph:out_neighbours(Graph, Name).

fanout_failure(_Config) ->
    try coop_flow:fanout(a, 8, self())
    catch error:function_clause -> ok
    end,
    
    try coop_flow:fanout(#coop_dag_node{}, a, self())
    catch error:function_clause -> ok
    end.

fanout_flow(_Config) ->
    Self = self(),
    Router_Fn = #coop_dag_node{
      name = inbound,
      label = #coop_node_fn{init={?MODULE, init, [f2]}, task={?MODULE, times3}}
     },
    Worker_Node_Fns = [#coop_dag_node{
                          name = N,
                          label = #coop_node_fn{init={?MODULE, init, [f3]}, task={?MODULE, minus5}}}
                       || N <- lists:seq(1,8)],
    Coop_Flow = coop_flow:fanout(Router_Fn, Worker_Node_Fns, Self),
    10 = digraph:no_vertices(Coop_Flow),
    16 = digraph:no_edges(Coop_Flow),
    check_fanout_vertex(Coop_Flow, Router_Fn, inbound,  0, 8),
    check_fanout_vertex(Coop_Flow, Self, outbound, 8, 0),
    [check_fanout_vertex(Coop_Flow, 8, {N,#coop_node_fn{}}, 1, 1) || N <- lists:seq(1,8)].
