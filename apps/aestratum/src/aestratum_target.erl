-module(aestratum_target).

-export([recalculate/3]).

recalculate(PrevTargets, DesiredSolveTime, MaxTarget) when
      PrevTargets =/= [] ->
    N = length(PrevTargets),
    K = MaxTarget * (1 bsl 32),
    {SumKDivTargets, SumSolveTime} =
        lists:foldl(
          fun({Target, SolveTime}, {SumKDivTargets0, SumSolveTime0}) ->
                  {(K div Target) + SumKDivTargets0, SolveTime + SumSolveTime0}
          end, {0, 0}, PrevTargets),
    TemperedTST = (3 * N * DesiredSolveTime) div 4 + (2523 * SumSolveTime) div 10000,
    NewTarget = TemperedTST * K div (DesiredSolveTime * SumKDivTargets),
    min(MaxTarget, NewTarget);
recalculate([], _DesiredSolveTime, MaxTarget) ->
    MaxTarget.

