#!/usr/bin/env bash
# ==============================================================================
#  The use of this file without proper attribution to the original author (G-grbz - https://github.com/G-grbz)
 # and without obtaining permission is considered unethical and is not permitted.
# ==============================================================================
# Copyright (c) 2025 G-grbz. All rights reserved.
# ==============================================================================
set -euo pipefail
export LC_ALL=C

VERSION="trailersurl-nfo.sh v3.1 (URL-only, NFO-based, max=1, with summary)"
echo "[INFO] $VERSION" >&2
[[ "${BASH:-}" ]] || { echo "[HATA] Bu script bash gerektirir. 'bash trailersurl-nfo.sh' ile çalıştır." >&2; exit 2; }

JF_BASE="${JF_BASE:-http://localhost:8096}"
JF_API_KEY="${JF_API_KEY:-CHANGE_ME}"
TMDB_API_KEY="${TMDB_API_KEY:-CHANGE_ME}"
PREFERRED_LANG="${PREFERRED_LANG:-tr-TR}"
FALLBACK_LANG="${FALLBACK_LANG:-en-US}"
INCLUDE_TYPES="${INCLUDE_TYPES:-Movie,Series,Season,Episode}"
PAGE_SIZE="${PAGE_SIZE:-200}"
SLEEP_SECS="${SLEEP_SECS:-0.5}"
JF_USER_ID="${JF_USER_ID:-}"

PREFERRED_ISO639="${PREFERRED_LANG%%-*}"
FALLBACK_ISO639="${FALLBACK_LANG%%-*}"
INCLUDE_LANGS_WIDE="${INCLUDE_LANGS_WIDE:-tr,en,hi,de,ru,fr,it,es,ar,fa,pt,zh,ja,ko,nl,pl,sv,cs,uk,el,null}"

need() { command -v "$1" >/dev/null || { echo "Hata: $1 kurulu değil." >&2; exit 1; }; }
need curl; need jq

[[ "$JF_API_KEY" != "CHANGE_ME" && "$TMDB_API_KEY" != "CHANGE_ME" ]] \
  || { echo "Hata: JF_API_KEY ve TMDB_API_KEY ayarla." >&2; exit 1; }

api() { curl -sS --fail "$@"; }

CNT_TOTAL=0
CNT_OK=0
CNT_SKIP_HAS=0
CNT_NOT_FOUND=0
CNT_FAIL_WRITE=0
CNT_FAIL_REFRESH=0
CNT_UNSUPPORTED=0
CNT_NO_PATH=0
CNT_NO_TMDB=0
CNT_MISC=0

resolve_user_id() {
  [[ -n "${JF_USER_ID:-}" ]] && { echo "$JF_USER_ID"; return 0; }
  local users; users=$(api -H "X-Emby-Token: $JF_API_KEY" "$JF_BASE/Users") || return 1
  local uid; uid=$(echo "$users" | jq -r '[.[] | select(.Policy.IsAdministrator==true)][0].Id // .[0].Id // empty')
  [[ -n "$uid" ]] || { echo "[HATA] Kullanıcı bulunamadı." >&2; return 2; }
  echo "$uid"
}

imdb_to_tmdb() {
  local imdb_id="$1" kind_hint="${2:-Unknown}"
  local r; r=$(api "https://api.themoviedb.org/3/find/${imdb_id}?api_key=${TMDB_API_KEY}&external_source=imdb_id") || return 1
  local mid tv
  mid=$(echo "$r" | jq -r '.movie_results[0].id // empty')
  tv=$(echo "$r" | jq -r '.tv_results[0].id // empty')
  if [[ -n "$mid" && ( "$kind_hint" == "Movie" || "$kind_hint" == "Unknown" ) ]]; then echo "Movie:$mid"; return 0; fi
  if [[ -n "$tv" && ( "$kind_hint" == "Series" || "$kind_hint" == "Unknown" ) ]]; then echo "Series:$tv"; return 0; fi
  [[ -n "$mid" ]] && { echo "Movie:$mid"; return 0; }
  [[ -n "$tv" ]] && { echo "Series:$tv"; return 0; }
  return 2
}

jq_trailer_defs='
  def ytid:
    tostring
    | if test("^[A-Za-z0-9_-]{11}$") then .
      elif test("[\\?&]v=([A-Za-z0-9_-]{11})") then capture("[\\?&]v=(?<id>[A-Za-z0-9_-]{11})").id
      elif test("youtu\\.be/([A-Za-z0-9_-]{11})") then capture("youtu\\.be/(?<id>[A-Za-z0-9_-]{11})").id
      else empty end;
  def vimeoid:
    tostring
    | if test("^[0-9]+$") then .
      elif (match("([0-9]{6,})")? != null) then (match("([0-9]{6,})").captures[0].string)
      else empty end;
  def filt:
    (.results // [])
    | map(select((.site|ascii_downcase)=="youtube" or (.site|ascii_downcase)=="vimeo"))
    | ( ( map(select((.type|ascii_downcase)=="trailer"))
          + map(select((.type|ascii_downcase)=="teaser")) ) )
    | map({ site:(.site|ascii_downcase), key_raw:(.key|tostring // "") })
    | map(if .site=="youtube" then . + {key:(.key_raw|ytid)}
          elif .site=="vimeo" then . + {key:(.key_raw|vimeoid)}
          else . + {key:""} end)
    | map(select(.key != null and (.key|type)=="string" and (.key|length)>0))
    | map("\(.site)|\(.key)")
    | reduce .[] as $x ([]; if (index($x)) then . else . + [$x] end)
    | .[] ;
'

find_trailer_keys_movie() {
  local tmdb_id="$1"
  local base="api_key=${TMDB_API_KEY}&language=${PREFERRED_LANG}&include_video_language=${PREFERRED_ISO639},${FALLBACK_ISO639},en,null"
  local r; r=$(api "https://api.themoviedb.org/3/movie/${tmdb_id}/videos?${base}" 2>/dev/null || echo '{"results":[]}')
  local lines; lines=$(printf '%s' "$r" | jq -r "$jq_trailer_defs filt")
  [[ -n "$lines" ]] && { printf '%s\n' "$lines"; return 0; }
  local wide="api_key=${TMDB_API_KEY}&language=${PREFERRED_LANG}&include_video_language=${INCLUDE_LANGS_WIDE}"
  r=$(api "https://api.themoviedb.org/3/movie/${tmdb_id}/videos?${wide}" 2>/dev/null || echo '{"results":[]}')
  printf '%s' "$r" | jq -r "$jq_trailer_defs filt" || true
}

find_trailer_keys_tv() {
  local tv_id="$1" season_no="${2:-}" episode_no="${3:-}"
  local base="api_key=${TMDB_API_KEY}&language=${PREFERRED_LANG}&include_video_language=${PREFERRED_ISO639},${FALLBACK_ISO639},en,null"
  if [[ -n "$episode_no" && -n "$season_no" ]]; then
    local url_ep="https://api.themoviedb.org/3/tv/${tv_id}/season/${season_no}/episode/${episode_no}/videos?${base}"
    local r; r=$(api "$url_ep" 2>/dev/null || echo '{"results":[]}')
    local lines; lines=$(printf '%s' "$r" | jq -r "$jq_trailer_defs filt")
    [[ -n "$lines" ]] && { printf '%s\n' "$lines"; return 0; }
  fi

  if [[ -n "$season_no" ]]; then
    local url_season="https://api.themoviedb.org/3/tv/${tv_id}/season/${season_no}/videos?${base}"
    local r; r=$(api "$url_season" 2>/dev/null || echo '{"results":[]}')
    local lines; lines=$(printf '%s' "$r" | jq -r "$jq_trailer_defs filt")
    [[ -n "$lines" ]] && { printf '%s\n' "$lines"; return 0; }
  fi

  local url_show="https://api.themoviedb.org/3/tv/${tv_id}/videos?${base}"
  local r; r=$(api "$url_show" 2>/dev/null || echo '{"results":[]}')
  local lines; lines=$(printf '%s' "$r" | jq -r "$jq_trailer_defs filt")
  [[ -n "$lines" ]] && { printf '%s\n' "$lines"; return 0; }

  local wide="api_key=${TMDB_API_KEY}&language=${PREFERRED_LANG}&include_video_language=${INCLUDE_LANGS_WIDE}"
  if [[ -n "$episode_no" && -n "$season_no" ]]; then
    r=$(api "https://api.themoviedb.org/3/tv/${tv_id}/season/${season_no}/episode/${episode_no}/videos?${wide}" 2>/dev/null || echo '{"results":[]}')
    lines=$(printf '%s' "$r" | jq -r "$jq_trailer_defs filt")
    [[ -n "$lines" ]] && { printf '%s\n' "$lines"; return 0; }
  fi

  if [[ -n "$season_no" ]]; then
    r=$(api "https://api.themoviedb.org/3/tv/${tv_id}/season/${season_no}/videos?${wide}" 2>/dev/null || echo '{"results":[]}')
    lines=$(printf '%s' "$r" | jq -r "$jq_trailer_defs filt")
    [[ -n "$lines" ]] && { printf '%s\n' "$lines"; return 0; }
  fi

  r=$(api "https://api.themoviedb.org/3/tv/${tv_id}/videos?${wide}" 2>/dev/null || echo '{"results":[]}')
  printf '%s' "$r" | jq -r "$jq_trailer_defs filt" || true
}


yt_plugin_url() { printf 'plugin://plugin.video.youtube/?action=play_video&videoid=%s' "$1"; }

build_trailer_url() {
  local site="$1" key="$2"
  if [[ "$site" == "youtube" ]]; then yt_plugin_url "$key"
  elif [[ "$site" == "vimeo" ]]; then printf 'https://vimeo.com/%s' "$key"
  else printf ''; fi
}

xml_escape() {
  local s="${1:-}"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  s="${s//\"/&quot;}"; s="${s//\'/&apos;}"
  printf '%s' "$s"
}

nfo_has_trailer() { [[ -f "$1" ]] && grep -qi "<trailer>.*</trailer>" "$1"; }

pick_nfo_path() {
  local type="$1" path="$2"
  local dir base name
  case "$type" in
    Movie)
      dir="$(dirname "$path")"; base="$(basename "$path")"; name="${base%.*}"
      if [[ -f "$dir/$name.nfo" ]]; then echo "$dir/$name.nfo|movie"; return 0; fi
      if [[ -f "$dir/movie.nfo" ]]; then echo "$dir/movie.nfo|movie"; return 0; fi
      echo "$dir/$name.nfo|movie"; return 0;;
    Episode)
      echo "${path%.*}.nfo|episodedetails"; return 0;;
    Series)
      echo "$path/tvshow.nfo|tvshow"; return 0;;
    Season)
      echo "$path/season.nfo|season"; return 0;;
    *) echo "|"; return 0;;
  esac
}

ensure_nfo_trailer() {
  local nfo="$1" root="$2" url_raw="$3"
  local url; url="$(xml_escape "$url_raw")"

  if nfo_has_trailer "$nfo"; then
    echo "[SKIP] NFO zaten trailer içeriyor: $nfo"
    return 1
  fi

  if [[ -f "$nfo" ]]; then
    if perl -0777 -pe "s#</$root>#  <trailer>$url</trailer>\n</$root>#i" -i "$nfo"; then
      echo "[OK] NFO güncellendi: $nfo"
      return 0
    else
      echo "[WARN] $nfo içine yazamadım."
      return 2
    fi
  else
    mkdir -p "$(dirname "$nfo")" || { echo "[WARN] NFO klasörü oluşturulamadı: $(dirname "$nfo")"; return 2; }
    cat > "$nfo" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<$root>
  <trailer>$url</trailer>
</$root>
EOF
    echo "[OK] NFO oluşturuldu: $nfo"
    return 0
  fi
}

process_item() {
  local id="$1" type="$2" name="$3" year="$4" path="$5" tmdb="$6" imdb="$7" user_id="$8"
  echo "[DEBUG] İşleniyor: $name ($type)" >&2
  if [[ "$type" == "Movie" ]]; then
    local tmdb_id="$tmdb"
    if [[ -z "$tmdb_id" && -n "$imdb" ]]; then
      local map; map=$(imdb_to_tmdb "$imdb" "Movie" || true)
      [[ -n "$map" ]] && tmdb_id="${map##*:}"
    fi
    if [[ -z "$tmdb_id" ]]; then
      echo "[ATLA] TMDb ID yok: $name"
      CNT_NO_TMDB=$((CNT_NO_TMDB+1))
      return 0
    fi

    while IFS= read -r raw; do
      local site="${raw%%|*}" key="${raw#*|}" url; url="$(build_trailer_url "$site" "$key")"
      [[ -z "$url" ]] && continue

      IFS='|' read -r nfo root <<<"$(pick_nfo_path "$type" "$path")"
      [[ -z "$nfo" || -z "$root" ]] && { echo "[ATLA] NFO yolu çözülemedi: $name"; CNT_MISC=$((CNT_MISC+1)); return 0; }

      if ensure_nfo_trailer "$nfo" "$root" "$url"; then
        curl -sS -X POST -H "X-Emby-Token: $JF_API_KEY" \
          "$JF_BASE/Items/$id/Refresh?Recursive=false&MetadataRefreshMode=FullRefresh&ImageRefreshMode=Default&ReplaceAllImages=false&ReplaceAllMetadata=false" >/dev/null \
          || { echo "[WARN] Refresh çağrısı başarısız: $name"; CNT_FAIL_REFRESH=$((CNT_FAIL_REFRESH+1)); }
        echo "[OK] $name -> $url"
        CNT_OK=$((CNT_OK+1))
        sleep "$SLEEP_SECS"
        return 0
      else
        case "$?" in
          1) CNT_SKIP_HAS=$((CNT_SKIP_HAS+1)); return 0;;
          2) CNT_FAIL_WRITE=$((CNT_FAIL_WRITE+1));;
          *) CNT_MISC=$((CNT_MISC+1));;
        esac
      fi
    done < <(find_trailer_keys_movie "$tmdb_id" || true)

    echo "[ATLA] Trailer bulunamadı: $name"
    CNT_NOT_FOUND=$((CNT_NOT_FOUND+1))
    return 0
  fi

  if [[ "$type" == "Episode" || "$type" == "Season" || "$type" == "Series" ]]; then
    local item; item=$(curl -sS -H "X-Emby-Token: $JF_API_KEY" \
      "$JF_BASE/Users/$user_id/Items/$id?Fields=SeriesId,SeasonId,IndexNumber,ParentIndexNumber,ProviderIds,Type" || true)
    local series_id=$(echo "$item" | jq -r '.SeriesId // empty')
    local idx=$(echo "$item" | jq -r '.IndexNumber // empty')
    local parent_idx=$(echo "$item" | jq -r '.ParentIndexNumber // empty')

    local series_tmdb="" season_no="" episode_no=""
    if [[ -n "$series_id" ]]; then
      local s; s=$(curl -sS -H "X-Emby-Token: $JF_API_KEY" "$JF_BASE/Users/$user_id/Items/$series_id?Fields=ProviderIds") || true
      series_tmdb=$(echo "$s" | jq -r '.ProviderIds.Tmdb // .ProviderIds.MovieDb // empty')
    fi
    [[ "$type" == "Episode" ]] && { episode_no="$idx"; season_no="$parent_idx"; }
    [[ "$type" == "Season"  ]] && season_no="$idx"

    if [[ -z "${series_tmdb:-}" ]]; then
      echo "[ATLA] Series TMDb yok: $name"
      CNT_NO_TMDB=$((CNT_NO_TMDB+1))
      return 0
    fi

    while IFS= read -r raw; do
      local site="${raw%%|*}" key="${raw#*|}" url; url="$(build_trailer_url "$site" "$key")"
      [[ -z "$url" ]] && continue

      IFS='|' read -r nfo root <<<"$(pick_nfo_path "$type" "$path")"
      [[ -z "$nfo" || -z "$root" ]] && { echo "[ATLA] NFO yolu çözülemedi: $name"; CNT_MISC=$((CNT_MISC+1)); return 0; }

      if ensure_nfo_trailer "$nfo" "$root" "$url"; then
        curl -sS -X POST -H "X-Emby-Token: $JF_API_KEY" \
          "$JF_BASE/Items/$id/Refresh?Recursive=false&MetadataRefreshMode=FullRefresh&ImageRefreshMode=Default&ReplaceAllImages=false&ReplaceAllMetadata=false" >/dev/null \
          || { echo "[WARN] Refresh çağrısı başarısız: $name"; CNT_FAIL_REFRESH=$((CNT_FAIL_REFRESH+1)); }
        echo "[OK] $name -> $url"
        CNT_OK=$((CNT_OK+1))
        sleep "$SLEEP_SECS"
        return 0
      else
        case "$?" in
          1) CNT_SKIP_HAS=$((CNT_SKIP_HAS+1)); return 0;;
          2) CNT_FAIL_WRITE=$((CNT_FAIL_WRITE+1));;
          *) CNT_MISC=$((CNT_MISC+1));;
        esac
      fi
    done < <(find_trailer_keys_tv "$series_tmdb" "${season_no:-}" "${episode_no:-}" || true)

    echo "[ATLA] Trailer bulunamadı: $name"
    CNT_NOT_FOUND=$((CNT_NOT_FOUND+1))
    return 0
  fi

  echo "[ATLA] Tür desteklenmiyor: $type - $name"
  CNT_UNSUPPORTED=$((CNT_UNSUPPORTED+1))
  return 0
}

main() {
  local user_id; user_id="$(resolve_user_id)"
  echo "[INFO] Kullanıcı: $user_id" >&2

  local start=0
  while :; do
    local url="${JF_BASE}/Items?IncludeItemTypes=${INCLUDE_TYPES}&Recursive=true&Fields=Path,ProviderIds,ProductionYear&StartIndex=${start}&Limit=${PAGE_SIZE}"
    local page; page=$(api -H "X-Emby-Token: $JF_API_KEY" "$url")
    local total; total=$(echo "$page" | jq -r '.TotalRecordCount // 0')
    if [[ ${start} -eq 0 ]]; then
      echo "JMSF::TOTAL=${total}"
    fi
    local items; items=$(echo "$page" | jq -c '.Items[]?')

    while IFS= read -r it; do
      local id=$(echo "$it"   | jq -r '.Id')
      local type=$(echo "$it" | jq -r '.Type')
      local name=$(echo "$it" | jq -r '.Name')
      local year=$(echo "$it" | jq -r '.ProductionYear // empty')
      local path=$(echo "$it" | jq -r '.Path // empty')
      local tmdb=$(echo "$it" | jq -r '.ProviderIds.Tmdb // .ProviderIds.MovieDb // empty')
      local imdb=$(echo "$it" | jq -r '.ProviderIds.Imdb // empty')

      if [[ -z "$path" ]]; then
        echo "[ATLA] Yol yok: $name"
        CNT_NO_PATH=$((CNT_NO_PATH+1))
        continue
      fi

      CNT_TOTAL=$((CNT_TOTAL+1))
      echo "JMSF::DONE=${CNT_TOTAL}"
      process_item "$id" "$type" "$name" "$year" "$path" "$tmdb" "$imdb" "$user_id" || true
    done <<< "$items"

    start=$((start + PAGE_SIZE))
    [[ $start -lt $total ]] || break
  done

  echo
  echo "===== ÖZET ====="
  echo "Toplam işlenen öğe      : $CNT_TOTAL"
  echo "Başarılı (NFO eklendi)  : $CNT_OK"
  echo "Atlandı (zaten vardı)   : $CNT_SKIP_HAS"
  echo "Trailer bulunamadı      : $CNT_NOT_FOUND"
  echo "NFO yazma hatası        : $CNT_FAIL_WRITE"
  echo "Refresh hatası          : $CNT_FAIL_REFRESH"
  echo "TMDb ID yok             : $CNT_NO_TMDB"
  echo "Yol (Path) yok          : $CNT_NO_PATH"
  echo "Desteklenmeyen tür      : $CNT_UNSUPPORTED"
  echo "Diğer/çeşitli           : $CNT_MISC"
  echo "========================"
}

main "$@"
