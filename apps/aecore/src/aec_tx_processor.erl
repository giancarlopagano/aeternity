%%% -*- erlang-indent-level:4; indent-tabs-mode: nil -*-
%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(aec_tx_processor).

-export([eval/2
        ]).

-export([ inc_account_nonce/3
        ]).

-include_lib("aecore/include/aec_hash.hrl").

-record(state, { trees      :: aec_trees:trees()
               , cache      :: #{}
               , env        :: #{}
               }).

-define(IS_HASH(_X_), (is_binary(_X_) andalso byte_size(_X_) =:= ?HASH_BYTES)).
-define(IS_VAR(_X_), (is_tuple(_X_)
                      andalso tuple_size(_X_) =:= 2
                      andalso var =:= element(1, _X_)
                      andalso is_atom(element(2, _X_)))).

-define(IS_VAR_OR_HASH(_X_), ?IS_HASH(_X_) orelse ?IS_VAR(_X_)).

%%%===================================================================
%%% API
%%%===================================================================

eval(Instructions, Trees) ->
    try {ok, eval_instructions(Instructions, new_state(Trees))}
    catch
        throw:{?MODULE, What} ->
            {error, What}
    end.


%%%===================================================================
%%% Internal functions
%%%===================================================================

%%%===================================================================
%%% Instruction evaluation

eval_instructions([I|Left], S) ->
    #state{} = S1 = eval_one(I, S),
    eval_instructions(Left, S1);
eval_instructions([], S) ->
    cache_write_through(S).

eval_one({spend, From, To, Amount}, S) when ?IS_HASH(From),
                                            ?IS_VAR_OR_HASH(To) ->
    spend(From, To, Amount, S);
eval_one({spend_fee, From, Amount}, S) when ?IS_HASH(From) ->
    spend_fee(From, Amount, S);
eval_one({check_account_balance, Pubkey, Balance}, S) when ?IS_HASH(Pubkey) ->
    check_account_balance(Pubkey, Balance, S);
eval_one({check_account_nonce, Pubkey, Nonce}, S) when ?IS_HASH(Pubkey) ->
    check_account_nonce(Pubkey, Nonce, S);
eval_one({inc_account_nonce, Pubkey, Nonce}, S) when ?IS_HASH(Pubkey) ->
    inc_account_nonce(Pubkey, Nonce, S);
eval_one({resolve_account, GivenType, Hash, Var}, S) when ?IS_HASH(Hash),
                                                          ?IS_VAR(Var) ->
    resolve_name(account, GivenType, Hash, Var, S);
eval_one({ensure_account, Key}, S) when ?IS_VAR_OR_HASH(Key) ->
    {_Account, S1} = ensure_account(Key, S),
    S1.

new_state(Trees) ->
    #state{ trees = Trees
          , cache = dict:new()
          , env   = dict:new()
          }.

%%%===================================================================
%%% Operations
%%%
%%% NOTE: Must return a new state
%%%

inc_account_nonce(Key, Nonce, #state{} = S) ->
    {Account, S1} = get_account(Key, S),
    assert_account_nonce(Account, Nonce),
    Account1 = aec_accounts:set_nonce(Account, Nonce),
    cache_put(account, Account1, S1).

check_account_nonce(Key, Nonce, #state{} = S) ->
    {Account, S1} = get_account(Key, S),
    assert_account_nonce(Account, Nonce),
    S1.

check_account_balance(Key, Balance, #state{} = S) ->
    {Account, S1} = get_account(Key, S),
    case aec_accounts:balance(Account) of
        B when B >= Balance -> S1;
        B when B <  Balance -> runtime_error(insufficient_funds)
    end.

spend(From, To, Amount, #state{} = S) when is_integer(Amount), Amount >= 0 ->
    S1              = check_account_balance(From, Amount, S),
    {Sender1, S2}   = get_account(From, S1),
    {ok, Sender2}   = aec_accounts:spend_without_nonce_bump(Sender1, Amount),
    S3              = cache_put(account, Sender2, S2),
    {Receiver1, S4} = ensure_account(To, S3),
    {ok, Receiver2} = aec_accounts:earn(Receiver1, Amount),
    cache_put(account, Receiver2, S4).

spend_fee(From, Amount, #state{} = S) when is_integer(Amount), Amount >= 0 ->
    S1              = check_account_balance(From, Amount, S),
    {Sender1, S2}   = get_account(From, S1),
    {ok, Sender2}   = aec_accounts:spend_without_nonce_bump(Sender1, Amount),
    cache_put(account, Sender2, S2).


resolve_name(account, account, Pubkey, Var, S) ->
    set_var(Var, account, Pubkey, S);
resolve_name(account, name, NameHash, Var, S) ->
    Key = <<"account_pubkey">>,
    Trees = S#state.trees,
    %% TODO: Should cache the name as well.
    case aens:resolve_from_hash(Key, NameHash, aec_trees:ns(Trees)) of
        {ok, Id} ->
            %% Intentionally admissive to allow for all kinds of IDs for
            %% backwards compatibility.
            {_Tag, Pubkey} = aec_id:specialize(Id),
            set_var(Var, account, Pubkey, S);
        {error, What} ->
            runtime_error(What)
    end.

%%%===================================================================
%%% Helpers for instructions

assert_account_nonce(Account, Nonce) ->
    case aec_accounts:nonce(Account) of
        N when N + 1 =:= Nonce -> ok;
        N when N >= Nonce -> runtime_error(account_nonce_too_high);
        N when N < Nonce  -> runtime_error(account_nonce_too_low)
    end.

get_account(Key, #state{} = S) ->
    get_or_ensure_account(Key, get, S).

ensure_account(Key, #state{} = S) ->
    get_or_ensure_account(Key, ensure, S).

get_or_ensure_account(Key, Type, #state{} = S) ->
    case cache_find(account, Key, S) of
        none ->
            case trees_find(account, Key, S) of
                none when Type =:= get ->
                    runtime_error(account_not_found);
                none when Type =:= ensure ->
                    Pubkey = get_var(Key, account, S),
                    Account = aec_accounts:new(Pubkey, 0),
                    {Account, cache_put(account, Account, S)};
                {value, Account} ->
                    {Account, cache_put(account, Account, S)}
            end;
        {value, Account} ->
            {Account, S}
    end.

%%%===================================================================
%%% Error handling

-spec runtime_error(term()) -> no_return().
runtime_error(Error) ->
    throw({?MODULE, Error}).

%%%===================================================================
%%% Access to trees

trees_find(account, Key, #state{trees = Trees} = S) ->
    ATrees = aec_trees:accounts(Trees),
    aec_accounts_trees:lookup(get_var(Key, account, S), ATrees).

%%%===================================================================
%%% Cache

-define(IS_TAG(X), ((X =:= account)
                      orelse (X =:= var))).

cache_find(Tag, Key, #state{cache = C} = S) when ?IS_TAG(Tag) ->
    case dict:find({Tag, get_var(Key, Tag, S)}, C) of
        {ok, Val} -> {value, Val};
        error     -> none
    end.

cache_put(account, Val, #state{cache = C} = S) ->
    Pubkey = aec_accounts:pubkey(Val),
    S#state{cache = dict:store({account, Pubkey}, Val, C)}.

cache_write_through(#state{cache = C, trees = T}) ->
    dict:fold(fun cache_write_through_fun/3, T, C).

%% TODO: Should have a dirty flag.
cache_write_through_fun({account,_Pubkey}, Account, Trees) ->
    ATrees  = aec_trees:accounts(Trees),
    ATrees1 = aec_accounts_trees:enter(Account, ATrees),
    aec_trees:set_accounts(Trees, ATrees1).

%%%===================================================================
%%% Variable environment

get_var({var, X}, Tag, #state{env = E}) when is_atom(X) ->
    {Tag, Val} = dict:fetch(X, E),
    Val;
get_var(X,_Tag, #state{}) when is_binary(X) ->
    X.

set_var({var, X}, account = Tag, Pubkey, #state{} = S) when is_atom(X),
                                                            is_binary(Pubkey) ->
    S#state{env = dict:store(X, {Tag, Pubkey}, S#state.env)};
set_var(Var, Tag, Pubkey,_S) ->
    error({illegal_assignment, Var, Tag, Pubkey}).
