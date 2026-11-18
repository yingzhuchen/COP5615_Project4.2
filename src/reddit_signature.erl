%% RSA-2048 / RSA-SHA256 helpers for the Project 4.2 bonus.
-module(reddit_signature).
-include_lib("public_key/include/public_key.hrl").
-export([generate_key_pair/0, encode_public_key/1, decode_public_key/1,
         sign/2, verify/3, payload/4]).

generate_key_pair() ->
    application:ensure_all_started(public_key),
    Private = public_key:generate_key({rsa, 2048, 65537}),
    Public = #'RSAPublicKey'{modulus = Private#'RSAPrivateKey'.modulus,
                             publicExponent = Private#'RSAPrivateKey'.publicExponent},
    {encode_public_key(Public), Private}.

encode_public_key(Public = #'RSAPublicKey'{}) ->
    application:ensure_all_started(public_key),
    Entry = public_key:pem_entry_encode('RSAPublicKey', Public),
    public_key:pem_encode([Entry]).

decode_public_key(Pem) when is_binary(Pem) ->
    try
        [Entry | _] = public_key:pem_decode(Pem),
        {ok, public_key:pem_entry_decode(Entry)}
    catch
        _:_ -> {error, invalid_public_key}
    end;
decode_public_key(_) ->
    {error, invalid_public_key}.

sign(Private, Payload) ->
    application:ensure_all_started(public_key),
    Sig = public_key:sign(Payload, sha256, Private),
    base64:encode(Sig).

verify(Pem, Payload, Signature) ->
    case decode_public_key(Pem) of
        {ok, Public} ->
            try
                Sig = base64:decode(Signature),
                public_key:verify(Payload, sha256, Sig, Public)
            catch
                _:_ -> false
            end;
        {error, _} ->
            false
    end.

payload(User, Sub, Title, Body) ->
    <<(field(User))/binary, (field(Sub))/binary,
      (field(Title))/binary, (field(Body))/binary>>.

field(Value) ->
    Size = byte_size(Value),
    <<Size:32/big-unsigned-integer, Value/binary>>.
