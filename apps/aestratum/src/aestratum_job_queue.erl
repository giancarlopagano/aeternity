-module(aestratum_job_queue).

-export([new/0,
         add/2,
         member/2,
         get_front/1,
         get_rear/1,
         share_target/2
        ]).

-define(QUEUE_LEN_THRESHOLD, 3).
-define(MAX_JOBS, application:get_env(aestratum, max_jobs, 20)).

new() ->
    aestratum_lqueue:new(?MAX_JOBS).

add(Job, Queue) ->
    aestratum_lqueue:in({aestratum_job:id(Job), Job}, Queue).

member(Job, Queue) ->
    aestratum_lqueue:keymember(aestratum_job:id(Job), Queue).

%% Front - the oldest element of the queue.
get_front(Queue) ->
    aestratum_lqueue:get(Queue).

%% Rear - the newest element of the queue.
get_rear(Queue) ->
    aestratum_lqueue:get_r(Queue).

%% The job queue must have at least ?QUEUE_LEN_THRESHOLD items in order to
%% compute the new share target from the previous share targets. Otherwise,
%% the job's default target is returned.
share_target(Job, Queue) ->
    case aestratum_lqueue:len(Queue) of
        N when N >= ?QUEUE_LEN_THRESHOLD ->
            %% Share target is computed based on the previous share targets
            %% and their solve times.
            DesiredSolveTime = aestratum_job:desired_solve_time(Job),
            MaxTarget = aestratum_target:max(),
            {ok, share_target(DesiredSolveTime, MaxTarget, Queue)};
        _Other ->
            {error, not_enough_jobs}
    end.

%% Internal functions.

share_target(DesiredSolveTime, MaxTarget, Queue) ->
    TargetsWithSolveTime =
        [{aestratum_job:share_target(Job), aestratum_job:solve_time(Job)}
         || {_JobId, Job} <- aestratum_lqueue:to_list(Queue)],
    aestratum_target:recalculate(TargetsWithSolveTime, DesiredSolveTime, MaxTarget).

