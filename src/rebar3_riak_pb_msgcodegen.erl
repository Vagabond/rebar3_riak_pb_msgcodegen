%% @doc Generates a codec-mapping module from a CSV mapping of message
%% codes to messages in .proto files.
-module(rebar3_riak_pb_msgcodegen).
-behaviour(provider).

-export([init/1, do/1, format_error/1]).

%% -include_lib("rebar/include/rebar.hrl").
-define(FAIL, rebar_utils:abort()).
-define(ABORT(Str, Args), rebar_utils:abort(Str, Args)).

-define(CONSOLE(Str, Args), io:format(Str, Args)).

-define(DEBUG(Str, Args), rebar_log:log(debug, Str, Args)).
-define(INFO(Str, Args), rebar_log:log(info, Str, Args)).
-define(WARN(Str, Args), rebar_log:log(warn, Str, Args)).
-define(ERROR(Str, Args), rebar_log:log(error, Str, Args)).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

-define(MODULE_COMMENTS(CSV),
        ["%% @doc This module contains message code mappings generated from\n%% ",
         CSV,". DO NOT EDIT OR COMMIT THIS FILE!\n"]).

%% ===================================================================
%% Public API
%% ===================================================================


init(State) ->
    Provider = providers:create([
            {name, compile},          % The 'user friendly' name of the task
            {namespace, msgcodegen},
            {module, ?MODULE},          % The module implementation of the task
            {bare, true},               % The task can be run by the user, always true
            {deps, [default, app_discovery]},              % The list of dependencies
            {example, "rebar msgcodegen"}, % How to use the plugin
            {opts, []},                  % list of options understood by the plugin
            {short_desc, "example rebar3 msgcodegen"},
            {desc, ""}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    Apps = case rebar_state:current_app(State) of
               undefined ->
                   rebar_state:project_apps(State);
               AppInfo ->
                   [AppInfo]
           end,
    [begin
         Opts = rebar_app_info:opts(AppInfo),
         SourceDir = filename:join(rebar_app_info:dir(AppInfo), "src"),
         FoundFiles = rebar_utils:find_files(SourceDir, ".*\\.csv\$"),

         CompileFun = fun(Source, _Opts1) ->
                              Erl = fq_erl_file(Source),
                              case is_modified(Source, Erl) of
                                  false -> ok;
                                  true ->
                                      Tuples = load_csv(Source),
                                      Module = generate_module(mod_name(Source), Tuples),
                                      Formatted = erl_prettypr:format(Module),
                                      ok = file:write_file(Erl,
                                                           [?MODULE_COMMENTS(Source), Formatted]),
                                      rebar_api:info("Generated ~s~n", [Erl])
                              end
                      end,

         rebar_base_compiler:run(Opts, [], FoundFiles, CompileFun)
     end || AppInfo <- Apps],

    {ok, State}.

format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%% ===================================================================
%% Internal functions
%% ===================================================================

is_modified(CSV, Erl) ->
    not filelib:is_regular(Erl) orelse
        filelib:last_modified(CSV) > filelib:last_modified(Erl).

mod_name(SourceFile) ->
    filename:basename(SourceFile, ".csv").

fq_erl_file(SourceFile) ->
    filename:join(["src", erl_file(SourceFile)]).

erl_file(SourceFile) ->
    mod_name(SourceFile) ++ ".erl".

load_csv(SourceFile) ->
    {ok, Bin} = file:read_file(SourceFile),
    csv_to_tuples(unicode:characters_to_list(Bin, latin1)).

csv_to_tuples(String) ->
    Lines = string:tokens(String, [$\r,$\n]),
    [ begin
          [Code, Message, Proto] = string:tokens(Line, ","),
          {list_to_integer(Code), Message, Proto ++ "_pb"}
      end
     || Line <- Lines].

generate_module(Name, Tuples) ->
    %% TODO: Add generated doc comment at the top
    Mod = erl_syntax:attribute(erl_syntax:atom(module),
                               [erl_syntax:atom(Name)]),
    ExportsList = [
                    erl_syntax:arity_qualifier(erl_syntax:atom(Fun), erl_syntax:integer(1))
                    || Fun <- [msg_type, msg_code, decoder_for] ],

    Exports = erl_syntax:attribute(erl_syntax:atom(export),
                                   [erl_syntax:list(ExportsList)]),

    Clauses = generate_msg_type(Tuples) ++
              generate_msg_code(Tuples) ++
              generate_decoder_for(Tuples),

    erl_syntax:form_list([Mod, Exports|Clauses]).

generate_decoder_for(Tuples) ->
    Spec = erl_syntax:text("-spec decoder_for(non_neg_integer()) -> module().\n"),
    Name = erl_syntax:atom(decoder_for),
    Clauses = [
                erl_syntax:clause([erl_syntax:integer(Code)],
                                  none,
                                  [erl_syntax:atom(Mod)])
                || {Code, _, Mod} <- Tuples ],
    [ Spec, erl_syntax:function(Name, Clauses) ].

generate_msg_code(Tuples) ->
    Spec = erl_syntax:text("-spec msg_code(atom()) -> non_neg_integer()."),
    Name = erl_syntax:atom(msg_code),
    Clauses = [
               erl_syntax:clause([erl_syntax:atom(Msg)], none, [erl_syntax:integer(Code)])
               || {Code, Msg, _} <- Tuples ],
    [ Spec, erl_syntax:function(Name, Clauses) ].

generate_msg_type(Tuples) ->
    Spec = erl_syntax:text("-spec msg_type(non_neg_integer()) -> atom()."),
    Name = erl_syntax:atom(msg_type),
    Clauses = [
               erl_syntax:clause([erl_syntax:integer(Code)], none, [erl_syntax:atom(Msg)])
               || {Code, Msg, _} <- Tuples ],
    CatchAll = erl_syntax:clause([erl_syntax:underscore()], none, [erl_syntax:atom(undefined)]),
    [ Spec, erl_syntax:function(Name, Clauses ++ [CatchAll]) ].

delete_each([]) ->
    ok;
delete_each([File | Rest]) ->
    case file:delete(File) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            ?ERROR("Failed to delete ~s: ~p\n", [File, Reason])
    end,
    delete_each(Rest).
