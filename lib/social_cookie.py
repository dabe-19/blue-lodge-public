#!/usr/bin/env python3
"""
George: X (Twitter) Web Session / Cookie Automation Engine
Allows George to authenticate and post using a logged-in X user session (auth_token + ct0).
Leverages X Premium long-form post allowances with zero developer API fees.
"""

import sys
import json
import urllib.request
import urllib.error

WEB_BEARER = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

def get_headers(auth_token: str, ct0: str) -> dict:
    return {
        "Authorization": f"Bearer {WEB_BEARER}",
        "Cookie": f"auth_token={auth_token}; ct0={ct0}",
        "x-csrf-token": ct0,
        "x-twitter-auth-type": "OAuth2Session",
        "x-twitter-active-user": "yes",
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json",
        "Accept": "*/*",
        "Authority": "x.com"
    }

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

def post_tweet(auth_token: str, ct0: str, text: str, reply_to_id: str = None):
    # Standard GraphQL CreateTweet endpoint for X web
    url = "https://x.com/i/api/graphql/5V_dkq1kc5yWbv4m1BLxYA/CreateTweet"
    headers = get_headers(auth_token, ct0)
    
    variables = {
        "tweet_text": text,
        "dark_request": False,
        "media": {"media_entities": [], "possibly_sensitive": False},
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
            print(json.dumps({"status": "ok", "tweet_id": tweet_id, "raw": data}))
            return 0
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(json.dumps({"status": "error", "code": e.code, "detail": body}))
        return 1
    except Exception as e:
        print(json.dumps({"status": "error", "detail": str(e)}))
        return 1

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: social_cookie.py <verify|post> <auth_token> <ct0> [text] [reply_to_id]")
        sys.exit(1)

    action = sys.argv[1]
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
