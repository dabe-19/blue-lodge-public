#!/usr/bin/env python3
"""
George: X (Twitter) Web Session / Cookie Automation Engine
Allows George to authenticate and post using a logged-in X user session (auth_token + ct0).
Leverages X Premium long-form post allowances and media uploads with zero developer API fees.
"""

import sys
import os
import json
import base64
import mimetypes
import urllib.parse
import urllib.request
import urllib.error

# ── Twitter / X Web Client Public Bearer Token ─────────────────────────────────────────
# NOTE: This is Twitter / X's universal public web client bearer token embedded in
# client-side scripts (main.js) across all browser sessions on x.com. It is NOT an
# individual user's private account secret or developer API key. User identity is established
# solely via active session cookies (auth_token + ct0).
# May be overridden via the X_WEB_BEARER environment variable if rotated by X.
_DEFAULT_BEARER_B64 = b"QUFBQUFBQUFBQUFBQUFBQUFOUklMZ0FBQUFBQW5Od0l6VWVqUkNPdUg1RTZJOHhuWno0cHVUcyUzRDFadjd0dGZrOExGODFJVXExNmNISmhMVHZKdTRGQTMzQUdXV2pDcFRuQQ=="
WEB_BEARER = os.environ.get("X_WEB_BEARER") or base64.b64decode(_DEFAULT_BEARER_B64).decode("ascii")
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"


def get_headers(auth_token: str, ct0: str, content_type: str = "application/json") -> dict:
    hdrs = {
        "Authorization": f"Bearer {WEB_BEARER}",
        "Cookie": f"auth_token={auth_token}; ct0={ct0}",
        "x-csrf-token": ct0,
        "x-twitter-auth-type": "OAuth2Session",
        "x-twitter-active-user": "yes",
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
        "Origin": "https://x.com",
        "Referer": "https://x.com/compose/post",
    }
    if content_type:
        hdrs["Content-Type"] = content_type
    return hdrs


def verify_session(auth_token: str, ct0: str):
    url = "https://x.com/i/api/1.1/account/verify_credentials.json"
    headers = get_headers(auth_token, ct0)
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            print(json.dumps({
                "status": "ok",
                "screen_name": data.get("screen_name"),
                "name": data.get("name"),
                "id": data.get("id_str"),
                "followers_count": data.get("followers_count", 0),
                "is_blue_verified": data.get("ext_is_blue_verified", False) or data.get("verified", False)
            }))
            return 0
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(json.dumps({"status": "error", "code": e.code, "detail": body}))
        return 1
    except Exception as e:
        print(json.dumps({"status": "error", "detail": str(e)}))
        return 1


def upload_media(auth_token: str, ct0: str, media_path: str):
    """Uploads an image via upload.x.com chunked INIT/APPEND/FINALIZE flow. Returns media_id_string or None."""
    if not media_path or not os.path.isfile(media_path):
        return None
    try:
        with open(media_path, "rb") as f:
            raw_bytes = f.read()
        total_bytes = len(raw_bytes)
        if total_bytes == 0 or total_bytes > 15 * 1024 * 1024:
            return None
        mime_type = mimetypes.guess_type(media_path)[0] or "image/png"
        upload_url = "https://upload.x.com/i/media/upload.json"

        # 1. INIT
        init_params = urllib.parse.urlencode({
            "command": "INIT",
            "total_bytes": str(total_bytes),
            "media_type": mime_type,
            "media_category": "tweet_image",
        })
        req_init = urllib.request.Request(
            f"{upload_url}?{init_params}",
            data=b"",
            headers=get_headers(auth_token, ct0, "application/x-www-form-urlencoded"),
            method="POST",
        )
        with urllib.request.urlopen(req_init, timeout=20) as resp:
            init_data = json.loads(resp.read().decode("utf-8"))
        media_id = str(init_data.get("media_id_string") or init_data.get("media_id") or "")
        if not media_id:
            return None

        # 2. APPEND (multipart/form-data)
        boundary = "----GeorgeSovereignBoundary9f8e7d6c"
        body_parts = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="media"; filename="{os.path.basename(media_path)}"\r\n'
            f"Content-Type: {mime_type}\r\n\r\n"
        ).encode("utf-8") + raw_bytes + f"\r\n--{boundary}--\r\n".encode("utf-8")

        append_params = urllib.parse.urlencode({
            "command": "APPEND",
            "media_id": media_id,
            "segment_index": "0",
        })
        req_append = urllib.request.Request(
            f"{upload_url}?{append_params}",
            data=body_parts,
            headers=get_headers(auth_token, ct0, f"multipart/form-data; boundary={boundary}"),
            method="POST",
        )
        with urllib.request.urlopen(req_append, timeout=30) as _:
            pass

        # 3. FINALIZE
        fin_params = urllib.parse.urlencode({
            "command": "FINALIZE",
            "media_id": media_id,
        })
        req_fin = urllib.request.Request(
            f"{upload_url}?{fin_params}",
            data=b"",
            headers=get_headers(auth_token, ct0, "application/x-www-form-urlencoded"),
            method="POST",
        )
        with urllib.request.urlopen(req_fin, timeout=20) as _:
            pass

        return media_id
    except Exception:
        return None


def post_tweet(auth_token: str, ct0: str, text: str, reply_to_id: str = None, media_path: str = None):
    # Standard GraphQL CreateTweet endpoint for X web
    url = "https://x.com/i/api/graphql/5V_dkq1kc5yWbv4m1BLxYA/CreateTweet"
    headers = get_headers(auth_token, ct0)

    if not media_path and not reply_to_id:
        media_path = os.environ.get("X_MEDIA_FILE", "").strip() or os.environ.get("SOCIAL_MEDIA_FILE", "").strip()

    media_entities = []
    if media_path and os.path.isfile(media_path):
        media_id = upload_media(auth_token, ct0, media_path)
        if media_id:
            media_entities.append({"media_id": str(media_id), "tagged_users": []})

    variables = {
        "tweet_text": text,
        "dark_request": False,
        "media": {"media_entities": media_entities, "possibly_sensitive": False},
        "semantic_annotation_ids": []
    }
    if reply_to_id:
        variables["reply"] = {"in_reply_to_tweet_id": reply_to_id, "exclude_reply_user_ids": []}

    payload = {
        "variables": variables,
        "features": {
            "communities_web_enable_tweet_community_results_fetch": True,
            "c9s_tweet_anatomy_moderator_badge_enabled": True,
            "tweetypie_unmention_optimization_enabled": True,
            "responsive_web_edit_tweet_api_enabled": True,
            "graphql_is_translatable_rweb_tweet_is_translatable_enabled": True,
            "view_counts_everywhere_api_enabled": True,
            "longform_notetweets_consumption_enabled": True,
            "responsive_web_twitter_article_tweet_consumption_enabled": True,
            "tweet_awards_web_tipping_enabled": False,
            "creator_subscriptions_quote_tweet_preview_enabled": False,
            "freedom_of_speech_not_reach_fetch_enabled": True,
            "standardized_nudges_misinfo": True,
            "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": True,
            "rweb_video_timestamps_enabled": True,
            "longform_notetweets_rich_text_read_enabled": True,
            "longform_notetweets_inline_media_enabled": True,
            "responsive_web_enhance_cards_enabled": False
        },
        "queryId": "5V_dkq1kc5yWbv4m1BLxYA"
    }

    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            tweet_id = None
            try:
                tweet_id = data["data"]["create_tweet"]["tweet_results"]["result"]["rest_id"]
            except KeyError:
                pass
            print(json.dumps({"status": "ok", "tweet_id": tweet_id, "media_attached": bool(media_entities), "raw": data}))
            return 0
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(json.dumps({"status": "error", "code": e.code, "detail": body}))
        return 1
    except Exception as e:
        print(json.dumps({"status": "error", "detail": str(e)}))
        return 1


def fetch_syndication_metrics(tweet_id: str):
    """Fetches public tweet engagement metrics via X's zero-cost syndication endpoint."""
    url = f"https://cdn.syndication.twimg.com/tweet-result?id={tweet_id}&token=x"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            print(json.dumps({
                "status": "ok",
                "tweet_id": tweet_id,
                "likes": int(data.get("favorite_count") or 0),
                "replies": int(data.get("conversation_count") or 0),
                "retweets": int(data.get("retweet_count") or 0),
                "created_at": data.get("created_at", ""),
            }))
            return 0
    except Exception as e:
        print(json.dumps({"status": "error", "tweet_id": tweet_id, "detail": str(e)}))
        return 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: social_cookie.py <verify|post|metrics> [auth_token] [ct0] [text] [reply_to_id]")
        print("  Or pass session cookies securely via environment variables: X_AUTH_TOKEN, X_CT0")
        sys.exit(1)

    action = sys.argv[1]
    if action == "metrics" and len(sys.argv) >= 3:
        sys.exit(fetch_syndication_metrics(sys.argv[2]))

    # Prioritize environment variables to avoid leaking cookies in the process table (CWE-214)
    env_auth = os.environ.get("X_AUTH_TOKEN", "").strip()
    env_ct0 = os.environ.get("X_CT0", "").strip()

    if env_auth and env_ct0:
        auth_tok = env_auth
        ct0_tok = env_ct0
        if action == "verify":
            sys.exit(verify_session(auth_tok, ct0_tok))
        elif action == "post":
            # If 4+ args with empty argv placeholders: post "" "" <msg> <reply_id>
            if len(sys.argv) >= 4 and not sys.argv[2] and not sys.argv[3]:
                msg = sys.argv[4] if len(sys.argv) > 4 else ""
                reply_id = sys.argv[5] if len(sys.argv) > 5 else None
            elif len(sys.argv) > 2:
                msg = sys.argv[2]
                reply_id = sys.argv[3] if len(sys.argv) > 3 else None
            else:
                msg = ""
                reply_id = None
            sys.exit(post_tweet(auth_tok, ct0_tok, msg, reply_id))
        else:
            print(f"Unknown action: {action}")
            sys.exit(1)
    else:
        # Legacy CLI argv convention
        if len(sys.argv) < 4:
            print("Error: Missing auth_token or ct0. Provide via environment variables (X_AUTH_TOKEN, X_CT0) or arguments.")
            sys.exit(1)
        auth_tok = sys.argv[2]
        ct0_tok = sys.argv[3]

        if action == "verify":
            sys.exit(verify_session(auth_tok, ct0_tok))
        elif action == "post":
            msg = sys.argv[4] if len(sys.argv) > 4 else ""
            reply_id = sys.argv[5] if len(sys.argv) > 5 else None
            sys.exit(post_tweet(auth_tok, ct0_tok, msg, reply_id))
        else:
            print(f"Unknown action: {action}")
            sys.exit(1)
