#!/usr/bin/env bash
# The kind x host decision for customs (spec, section 3).
#
# A host is trusted for its own kinds of secret only: a GitHub token headed to
# api.anthropic.com is the mistake worth catching, so there is no "trusted
# host" that receives everything. Built-in pairs live here, not in config.json,
# because the config loader replaces arrays on merge and a user's pair would
# drop the built-ins (see customs-config.sh). User pairs ADD to these.
#
# Exposes:
#   customs_decide <kinds> <hosts> <user-pairs> <record-only>   allow | record | flag
#   customs_reason <kinds> <hosts>                              one line, no values

_CUSTOMS_BUILTIN_PAIRS='{
	"github_token": ["github.com", "api.github.com", "uploads.github.com"],
	"anthropic_key": ["api.anthropic.com"],
	"openai_key": ["api.openai.com"],
	"aws_access_key_id": ["*.amazonaws.com"]
}'

# allow  - every gated kind is headed only to hosts paired with it
# record - nothing gated is out of place, but a record-only kind is present
# flag   - a gated kind is headed somewhere unpaired, or nowhere readable
customs_decide() {
	local kinds="${1:-[]}" hosts="${2:-[]}" user="${3:-}" record="${4:-}"
	[[ -z "$user" ]] && user='{}'
	[[ -z "$record" ]] && record='[]'

	jq -nr \
		--argjson kinds "$kinds" \
		--argjson hosts "$hosts" \
		--argjson builtin "$_CUSTOMS_BUILTIN_PAIRS" \
		--argjson user "$user" \
		--argjson record "$record" '
		($user | if type == "object" then . else {} end) as $user
		| ($record | if type == "array" then . else [] end) as $record
		| def matches($h; $p):
			if ($p | startswith("*.")) then
				($h == ($p | ltrimstr("*."))) or ($h | endswith($p | ltrimstr("*")))
			else $h == $p end;
		  def allowed($k):
			($builtin[$k] // []) + (($user[$k] // []) | if type == "array" then map(select(type == "string")) else [] end);
		  ($kinds | map(. as $k | select($record | any(. == $k) | not))) as $gated
		| if ($gated | length) == 0 then "record"
		  elif ($hosts | length) == 0 then "flag"
		  elif all($gated[]; . as $k | all($hosts[]; . as $h | any(allowed($k)[]; . as $p | matches($h; $p))))
		  then (if ($kinds | length) > ($gated | length) then "record" else "allow" end)
		  else "flag" end'
}

customs_reason() {
	jq -nr --argjson kinds "${1:-[]}" --argjson hosts "${2:-[]}" '
		{
			"github_token": "a GitHub token",
			"anthropic_key": "an Anthropic API key",
			"openai_key": "an OpenAI-style API key",
			"aws_access_key_id": "an AWS access key id",
			"bearer_token": "a bearer token"
		} as $label
		| ($kinds | map($label[.] // .) | join(" and ")) as $what
		| (if ($hosts | length) == 0 then "a host customs could not read from this call"
		   else ($hosts | join(", ")) end) as $where
		| "customs: \($what) is headed to \($where), which is not on the allowlist for it. Approve only if you meant to send it there. To allow it every time, add the host under customs.pairs in .claude/settings.json."'
}
