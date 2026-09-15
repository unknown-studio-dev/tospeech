#!/usr/bin/env python3
"""Generate candidate phoneme clips (UK and US) with ElevenLabs v3 IPA input.

Release-preparation tool, not an app runtime dependency. The sound inventory is
scripts/resources/cambridge-phoneme-set.json (58 symbols from Cambridge's
phonetics help page; 54 UK + 49 US = 103 clips). Nothing is downloaded from
Cambridge: every clip is synthesized from IPA with a licensed ElevenLabs voice.

Subcommands
  voices    list premade voices by accent (id, name, labels)
  generate  synthesize N candidates per sound/variant/accent, cut and normalise
  review    write review.html (candidates next to the current bundled clip)
  finalize  copy selected clips: the 44 RP sounds into ToSpeech/Resources/UKPhonemes
            (UKPhoneme_XX.wav order from UKSoundLibrary.swift) and the full pack
            into <out>/pack/<accent>/<symbol>.wav

Requires python3, ffmpeg, and an API key in $ELEVENLABS_API_KEY or
~/.config/elevenlabs/api_key.
"""
import argparse, base64, html, json, os, re, struct, subprocess, sys, time, urllib.error, urllib.parse, urllib.request, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ROOT / "scripts/resources/cambridge-phoneme-set.json"
LIBRARY = ROOT / "ToSpeech/Domain/Rules/UKSoundLibrary.swift"
DEST = ROOT / "ToSpeech/Resources/UKPhonemes"
API = "https://api.elevenlabs.io"
MODEL = "eleven_v3"
CARRIER = "ɑː"  # VCV frame vowel: open, unrounded, easy to cut around
SUSTAINABLE = {"f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "m", "n", "ŋ", "l", "x"}
APP_ALIASES = {"g": "ɡ", "r": "ɹ"}  # Cambridge spelling -> UKSoundLibrary spelling


def inventory():
    doc = json.loads(INVENTORY.read_text(encoding="utf-8"))
    return doc["sounds"]


def clip_items(accents):
    """One item per (accent, sound). ids look like uk-05."""
    items = []
    for accent in accents:
        n = 0
        for sound in inventory():
            if accent not in sound["accents"]:
                continue
            n += 1
            items.append({"id": f"{accent}-{n:02d}", "accent": accent, **sound})
    return items


def variants(item):
    """(name, text, target): target is the IPA span kept from the alignment."""
    s = item["symbol"]
    if s == "t̬":
        return [("vcv", "/ˈɑːt̬ə/", s)]
    if item["group"] == "vowels":
        return [("iso", f"/ˈ{s}/", s)]
    if item["group"] == "other":
        return [("iso", f"/{s}/", s)] if s in ("əl", "əm", "ən", "ər", "i", "u", "ɒ̃") else [("iso", f"/ˈ{s}/", s)]
    iso = ("iso", f"/{s}/", s)
    vcv = ("vcv", f"/ˈ{CARRIER}{s}{CARRIER}/", s)
    return [iso, vcv] if s in SUSTAINABLE else [vcv, iso]


def rp44():
    """The 44 UKSoundLibrary symbols in bundled order (UKPhoneme_01..44)."""
    text = LIBRARY.read_text(encoding="utf-8")
    symbols = re.findall(r'symbol:\s*"([^"]+)",\s*group:', text)
    if len(symbols) != 44:
        sys.exit(f"Expected 44 symbols in {LIBRARY}, found {len(symbols)}")
    return symbols


def api_key(args):
    path = Path(args.api_key_file).expanduser()
    if path.exists():
        return path.read_text().strip()
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("No API key: set ELEVENLABS_API_KEY or write it to ~/.config/elevenlabs/api_key")
    return key


def request(key, method, path, body=None, query=None):
    url = API + path + (("?" + urllib.parse.urlencode(query)) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
        headers={"xi-api-key": key, "Content-Type": "application/json", "Accept": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
                return json.loads(raw) if r.headers.get("Content-Type", "").startswith("application/json") else raw
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            if e.code == 429 and attempt < 3:
                time.sleep(3 * (attempt + 1)); continue
            raise RuntimeError(f"HTTP {e.code} {path}: {detail[:400]}") from None


def cmd_voices(args):
    key = api_key(args)
    rows = []
    for voice_type in ("default", "personal"):
        data = request(key, "GET", "/v2/voices", query={"page_size": 100, "voice_type": voice_type})
        for v in data.get("voices", []):
            labels = v.get("labels") or {}
            accent = (labels.get("accent") or "").lower()
            if args.all or any(k in accent for k in ("british", "american", "english")):
                rows.append((accent, labels.get("gender", ""), v["name"], v["voice_id"], voice_type, (v.get("description") or "")[:70]))
    for r in sorted(set(rows)):
        print("\t".join(r))


def resolve_voice(key, name_or_id):
    if re.fullmatch(r"[A-Za-z0-9]{20}", name_or_id):
        return name_or_id
    data = request(key, "GET", "/v2/voices", query={"page_size": 100, "search": name_or_id})
    for v in data.get("voices", []):
        if v["name"].lower() == name_or_id.lower():
            return v["voice_id"]
    sys.exit(f"Voice not found: {name_or_id}")


def synthesize(key, voice_id, text, stability):
    """Returns (mp3 bytes, alignment or None); falls back to plain convert if the
    timestamps endpoint rejects the model."""
    body = {"text": text, "model_id": MODEL, "voice_settings": {"stability": stability, "similarity_boost": 0.75}}
    try:
        data = request(key, "POST", f"/v1/text-to-speech/{voice_id}/with-timestamps", body, {"output_format": "mp3_44100_128"})
        return base64.b64decode(data["audio_base64"]), data.get("alignment") or data.get("normalized_alignment")
    except RuntimeError as e:
        if "HTTP 4" not in str(e):
            raise
        sys.stderr.write(f"  timestamps endpoint refused ({str(e)[:140]}); falling back to convert\n")
        raw = request(key, "POST", f"/v1/text-to-speech/{voice_id}", body, {"output_format": "mp3_44100_128"})
        return raw, None


def span_from_alignment(alignment, text, target):
    if not alignment:
        return None
    chars = alignment.get("characters") or []
    if "".join(chars) != text:
        return None
    start_index = text.find(target)
    if start_index < 0:
        return None
    idx = range(start_index, start_index + len(target))
    starts, ends = alignment["character_start_times_seconds"], alignment["character_end_times_seconds"]
    return min(starts[i] for i in idx), max(ends[i] for i in idx)


def decode_to_wav(src, dst):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src), "-vn", "-ar", "44100", "-ac", "1",
                    "-c:a", "pcm_s16le", str(dst)], check=True)


def rms_envelope(path, frame=0.005):
    with wave.open(str(path)) as w:
        rate, n = w.getframerate(), w.getnframes()
        samples = struct.unpack(f"<{n}h", w.readframes(n))
    size = max(1, int(rate * frame))
    env = [(sum(x * x for x in samples[i:i + size]) / len(samples[i:i + size])) ** 0.5 for i in range(0, len(samples), size)]
    return env, frame


def span_from_energy(path):
    """VCV fallback without timestamps: from the energy dip between the two
    vowels to the onset of the second vowel."""
    env, step = rms_envelope(path)
    if not env:
        return None
    peak = max(env)
    voiced = [i for i, e in enumerate(env) if e > 0.35 * peak]
    if len(voiced) < 4:
        return None
    gap, k = max((voiced[j + 1] - voiced[j], j) for j in range(len(voiced) - 1))
    if gap < 3:
        return None
    first_end, second_start = voiced[k], voiced[k + 1]
    dip = min(range(first_end, second_start + 1), key=lambda i: env[i])
    return dip * step, (second_start + 3) * step


def render(src_wav, dst_wav, span, pad_after):
    filters = []
    if span:
        filters.append(f"atrim=start={max(0.0, span[0] - 0.005):.4f}:end={span[1] + pad_after:.4f},asetpts=PTS-STARTPTS")
    filters.append("silenceremove=start_periods=1:start_duration=0.02:start_threshold=-48dB,areverse,"
                   "silenceremove=start_periods=1:start_duration=0.02:start_threshold=-48dB,areverse")
    filters.append("afade=t=in:st=0:d=0.012,loudnorm=I=-19:TP=-3:LRA=5,apad=pad_dur=0.035")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src_wav), "-af", ",".join(filters),
                    "-ar", "44100", "-ac", "1", "-c:a", "pcm_s16le", str(dst_wav)], check=True)
    with wave.open(str(dst_wav)) as w:
        duration = w.getnframes() / w.getframerate()
    tmp = dst_wav.with_suffix(".fade.wav")  # fade-out placed on the real clip end
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(dst_wav), "-af",
                    f"afade=t=out:st={max(0.0, duration - 0.047):.4f}:d=0.012", "-c:a", "pcm_s16le", str(tmp)], check=True)
    tmp.replace(dst_wav)
    return duration


def cmd_generate(args):
    if args.dry_run:
        key, voices = None, {"uk": args.uk_voice, "us": args.us_voice}
    else:
        key = api_key(args)
        voices = {"uk": resolve_voice(key, args.uk_voice), "us": resolve_voice(key, args.us_voice)}
    out = Path(args.out).expanduser(); (out / "raw").mkdir(parents=True, exist_ok=True); (out / "wav").mkdir(exist_ok=True)
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"model": MODEL, "voices": voices, "clips": {}}
    wanted = set(args.sounds.split(",")) if args.sounds else None
    for item in clip_items(args.accents.split(",")):
        if wanted and item["id"] not in wanted and item["symbol"] not in wanted:
            continue
        for name, text, target in variants(item):
            if args.variants and name not in args.variants.split(","):
                continue
            for c in range(1, args.candidates + 1):
                clip_id = f"{item['id']}-{name}-{c}"
                if clip_id in manifest["clips"] and not args.force:
                    continue
                if args.dry_run:
                    print(f"{clip_id:16s} {item['symbol']:4s} {item['example']:10s} {text}"); continue
                sys.stderr.write(f"{clip_id} {item['symbol']:4s} {text}\n")
                audio, alignment = synthesize(key, voices[item["accent"]], text, args.stability)
                raw_mp3 = out / "raw" / f"{clip_id}.mp3"; raw_mp3.write_bytes(audio)
                raw_wav = out / "raw" / f"{clip_id}.wav"; decode_to_wav(raw_mp3, raw_wav)
                if alignment:
                    (out / "raw" / f"{clip_id}.alignment.json").write_text(json.dumps(alignment))
                span, method, duration = cut_and_render(out, clip_id, name, text, target, alignment)
                manifest["clips"][clip_id] = {"item": item["id"], "accent": item["accent"], "symbol": item["symbol"], "variant": name,
                                              "candidate": c, "text": text, "cut": method, "span": span, "seconds": round(duration, 3)}
                manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
                time.sleep(args.delay)
    if not args.dry_run:
        print(f"{len(manifest['clips'])} clips in {out}")


def cut_and_render(out, clip_id, variant, text, target, alignment):
    """Isolated sounds are the whole utterance, so only silence is trimmed.
    VCV frames are cut at the energy dip between the two vowels; v3 character
    timestamps are evenly spaced estimates and only serve as a last resort."""
    raw_wav = out / "raw" / f"{clip_id}.wav"
    span, method = None, "trim"
    if variant == "vcv":
        span = span_from_energy(raw_wav); method = "energy"
        if not span:
            span = span_from_alignment(alignment, text, target); method = "timestamps" if span else "trim"
    duration = render(raw_wav, out / "wav" / f"{clip_id}.wav", span, 0.05 if variant == "vcv" else 0.0)
    return span, method, duration


def cmd_rerender(args):
    """Re-cut every clip from the saved raw audio after a policy change; no API calls."""
    out = Path(args.out).expanduser(); manifest_path = out / "manifest.json"; manifest = json.loads(manifest_path.read_text())
    for clip_id, clip in manifest["clips"].items():
        alignment_path = out / "raw" / f"{clip_id}.alignment.json"
        alignment = json.loads(alignment_path.read_text()) if alignment_path.exists() else None
        span, method, duration = cut_and_render(out, clip_id, clip["variant"], clip["text"], clip["symbol"], alignment)
        clip.update({"cut": method, "span": span, "seconds": round(duration, 3)})
        print(f"{clip_id:16s} {clip['symbol']:4s} {method:10s} {duration:.2f}s")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1))


def cmd_review(args):
    out = Path(args.out).expanduser(); manifest = json.loads((out / "manifest.json").read_text())
    current = out / "current"; current.mkdir(exist_ok=True)
    order = rp44(); rows = []
    for item in clip_items(["uk", "us"]):
        clips = sorted((k, v) for k, v in manifest["clips"].items() if v["item"] == item["id"])
        if not clips:
            continue
        app_symbol = APP_ALIASES.get(item["symbol"], item["symbol"])
        bundled = DEST / f"UKPhoneme_{order.index(app_symbol) + 1:02d}.wav" if item["accent"] == "uk" and app_symbol in order else None
        if bundled and bundled.exists():
            (current / bundled.name).write_bytes(bundled.read_bytes())
            keep = (f'<label class="c"><input type="radio" name="{item["id"]}" value="current" checked><span>giữ clip hiện tại</span>'
                    f'<audio controls preload="none" src="current/{bundled.name}"></audio></label>')
        else:
            keep = f'<label class="c"><input type="radio" name="{item["id"]}" value="none" checked><span>chưa chọn</span></label>'
        cells = "".join(
            f'<label class="c"><input type="radio" name="{item["id"]}" value="{k}">'
            f'<span>{v["variant"]} {v["candidate"]} · {v["seconds"]:.2f}s · {v["cut"]}</span>'
            f'<audio controls preload="none" src="wav/{k}.wav"></audio></label>' for k, v in clips)
        rows.append(f'<tr><th>{item["id"]} /{html.escape(item["symbol"])}/<br><small>{html.escape(item["example"])}</small></th>'
                    f'<td>{keep}</td><td>{cells}</td></tr>')
    page = f"""<!doctype html><meta charset="utf-8"><title>Phoneme candidates</title>
<style>body{{font:14px -apple-system,sans-serif;margin:16px}} table{{border-collapse:collapse;width:100%}} th,td{{border-top:1px solid #ddd;padding:8px;vertical-align:top;text-align:left}}
th{{width:9rem;font-size:20px}} .c{{display:inline-block;margin:0 12px 8px 0}} .c span{{display:block;font-size:12px;color:#555}} audio{{width:230px;height:32px}}
#sel{{width:100%;height:6rem;font-family:monospace}} .sticky{{position:sticky;top:0;background:#fff;padding:8px 0;border-bottom:1px solid #ccc}}</style>
<div class="sticky"><b>{html.escape(manifest["model"])} · UK {html.escape(manifest["voices"]["uk"])} · US {html.escape(manifest["voices"]["us"])}</b>
— chọn 1 clip mỗi hàng, bấm Copy rồi dán JSON lại cho Claude. <button onclick="collect()">Copy selection</button>
<button onclick="playAll()">Play all selected</button><br><textarea id="sel" readonly></textarea></div>
<table>{''.join(rows)}</table>
<script>
function collect(){{const o={{}};document.querySelectorAll('input[type=radio]:checked').forEach(r=>{{o[r.name]=r.value}});
const t=JSON.stringify(o);document.getElementById('sel').value=t;navigator.clipboard&&navigator.clipboard.writeText(t)}}
async function playAll(){{for(const r of document.querySelectorAll('input[type=radio]:checked')){{const a=r.parentElement.querySelector('audio');if(!a)continue;a.currentTime=0;await a.play();await new Promise(res=>a.onended=res);await new Promise(res=>setTimeout(res,350))}}}}
</script>"""
    (out / "review.html").write_text(page, encoding="utf-8")
    print(out / "review.html")


def cmd_finalize(args):
    out = Path(args.out).expanduser(); manifest = json.loads((out / "manifest.json").read_text())
    selection = json.loads(Path(args.selection).read_text())
    order = rp44(); pack = out / "pack"
    provenance = {"model": manifest["model"], "voices": manifest["voices"], "clips": {}}
    replaced = 0
    for item in clip_items(["uk", "us"]):
        choice = selection.get(item["id"])
        if not choice or choice in ("current", "none"):
            continue
        clip = manifest["clips"][choice]; src = out / "wav" / f"{choice}.wav"
        target = pack / item["accent"] / f"{item['symbol']}.wav"; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(src.read_bytes())
        app_symbol = APP_ALIASES.get(item["symbol"], item["symbol"])
        if item["accent"] == "uk" and app_symbol in order:
            dst = DEST / f"UKPhoneme_{order.index(app_symbol) + 1:02d}.wav"; dst.write_bytes(src.read_bytes()); replaced += 1
            provenance["clips"][dst.name] = {"symbol": item["symbol"], "text": clip["text"], "variant": clip["variant"], "cut": clip["cut"]}
            print(f"{dst.name} <- {choice} {clip['text']}")
    (DEST / "UKPhonemes-elevenlabs-provenance.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=1))
    print(f"Replaced {replaced} bundled RP clips; full pack in {pack}. Update UKPhonemes-README.md and THIRD_PARTY_NOTICES.md.")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--api-key-file", default="~/.config/elevenlabs/api_key")
    sub = p.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("voices"); v.add_argument("--all", action="store_true"); v.set_defaults(fn=cmd_voices)
    g = sub.add_parser("generate")
    g.add_argument("--uk-voice", required=True, help="voice_id or exact voice name, e.g. Lily")
    g.add_argument("--us-voice", required=True, help="voice_id or exact voice name, e.g. Sarah")
    g.add_argument("--out", required=True); g.add_argument("--candidates", type=int, default=3)
    g.add_argument("--accents", default="uk,us"); g.add_argument("--sounds", help="comma list of ids or symbols, e.g. uk-05,ʃ")
    g.add_argument("--variants", help="iso,vcv"); g.add_argument("--stability", type=float, default=0.5, help="v3: 0.0 creative, 0.5 natural, 1.0 robust")
    g.add_argument("--delay", type=float, default=0.4); g.add_argument("--force", action="store_true"); g.add_argument("--dry-run", action="store_true")
    g.set_defaults(fn=cmd_generate)
    rr = sub.add_parser("rerender"); rr.add_argument("--out", required=True); rr.set_defaults(fn=cmd_rerender)
    r = sub.add_parser("review"); r.add_argument("--out", required=True); r.set_defaults(fn=cmd_review)
    f = sub.add_parser("finalize"); f.add_argument("--out", required=True); f.add_argument("--selection", required=True); f.set_defaults(fn=cmd_finalize)
    args = p.parse_args(); args.fn(args)


if __name__ == "__main__":
    main()
