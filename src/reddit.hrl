%% Shared record definitions for the Reddit engine.
%%
%% Ids for posts and comments come from one counter, so an item id is unique
%% across both kinds. That lets votes, scores and the comment tree treat posts
%% and comments uniformly ("items").

-record(post, {
    id,                    % integer item id
    sub,                   % binary subreddit name
    author,                % binary user name
    title,                 % binary
    body,                  % binary, plain text
    created,               % ms since epoch
    repost_of = undefined, % id of the original post, or undefined
    signature = undefined  % base64-encoded RSA-SHA256 signature
}).

-record(comment, {
    id,       % integer item id
    post,     % id of the post this comment belongs to
    parent,   % id of the parent item (the post or another comment)
    author,
    body,
    created,
    depth     % 1 = direct reply to the post
}).

-record(dm, {
    id,                   % integer message id (separate counter)
    from,
    to,
    body,
    created,
    reply_to = undefined  % id of the message this one answers
}).
