# Drives Codex CLI to generate the coral-season art. Usage: python gen.py A|B [name ...]
# Skips outputs that already exist. Logs to logs/<name>.log.
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ["PATH"] = r"C:\Program Files\nodejs;" + os.path.join(os.environ["APPDATA"], "npm") + ";" + os.environ["PATH"]
CODEX = os.path.join(os.environ["APPDATA"], "npm", "codex.cmd")
MODEL = "gpt-6.2-sol"

STYLE = """Rendering style (taken from the game reference images, which are the style authority):
bold dark outlines of even weight, hand-painted cartoon game art with clear painted volume (base tone, shadow tone, crisp highlight), saturated but controlled colours, the same richness and ornament density as the references. NOT soft airbrush, NOT pastel sticker style, NOT glassy jelly UI, NOT 3D render, NOT flat vector icon.
Theme: OCEAN CORAL. Motifs: scallop shells, pearls, pink coral branches, seaweed, curling waves, bubbles, starfish, seabed stones.
Palette: sea blue #42B6E4, deep blue #2367AF, teal #80D8CD, shell pink #F6C5D9, coral pink #F394A7, pearl white #F9F0ED, lavender #B8A8EB, champagne gold #D4AA6C (gold low brightness, never shiny yellow).
Strictly NO crystals, NO gems, NO diamond or rhombus shapes, NO snowflakes, NO flowers, NO text or letters, no glow bloom."""

PALETTE_REF = "The LAST attached image is only a subject / palette reference from an earlier concept; do not copy its soft thin-line rendering."

def pet(name, concept, desc):
    return dict(out=f"pet_{name}_coral_v1.png",
        refs=["game_pet_rabbit.png", "game_pet_tiger.png", "game_pet_squirrel.png", "../samples/pet_jellyfish_coral_v1.png", concept],
        body=f"""A 2D game pet illustration. Attached images 1-3 are existing pets of my game, image 4 is the already approved ocean pet (bubble jellyfish) of this same set: match their style, pose language and detail level exactly. Chibi creature, 3/4 front pose, big glossy eyes with star catchlights, blush marks, wearing a small sea-blue cape or collar with champagne-gold trim fastened with a pearl, holding or carrying one themed prop. Square canvas, single character centred, fully transparent background, no ground shadow.
The LAST image is the character reference; keep its identity but redraw it in the game style.
Character: {desc}""")

def frame(name, desc):
    return dict(out=f"avatar_frame_{name}_v1.png",
        refs=["game_frame_sakura.png", "game_frame_frost.png", "game_frame_astral.png", "../samples/avatar_frame_coral_v1.png"],
        body=f"""A circular avatar frame. Attached images 1-3 are existing avatar frames of my game (structure and style authority: a solid ring, four ornament anchor points at top / bottom / left / right, theme decoration wrapped around). Image 4 is the already approved first ocean frame of this set; the new frame must look like a sibling of it but clearly different. Front view, square canvas, ring fills the canvas with a small margin, centre of the ring completely empty and transparent, fully transparent background.
Design: {desc}""")

def emote(name, char, concept, desc):
    refs = [f"../samples/pet_{char}_coral_v1.png", "game_pet_rabbit.png"] + ([concept] if concept else [])
    return dict(out=f"emote_{name}_v1.png", refs=refs,
        body=f"""A chat emote sticker for my game. Attached image 1 is the character sheet: keep exactly this character (same colours, cape, head ornament, proportions) and the same rendering style; image 2 is another pet of the game for style. {'The last image shows only the intended expression idea.' if concept else ''} Bust / upper-body close-up with an exaggerated readable expression, a thin pearl-white sticker outline around the whole silhouette, square canvas, fully transparent background, readable at 96 px.
Expression: {desc}""")

JOBS = {
 "A": [
  dict(out="skin_river.png", refs=["game_river_sakura.png", "game_river_ice.png", "game_river_nightwisp.png", "concept_board.png"],
       body="""The 'river' layer of a board skin. Attached images 1-3 are the same layer from three existing skins: a 16:9 canvas that is fully transparent except for a water strip across the bottom third, with a soft irregular shoreline at its top edge and a few rocks at the far left and right corners. Reproduce exactly that layout, strip height and transparency. New look: shallow tropical lagoon water, turquoise to sea blue with painted light ripples and a faint net of caustics, a few floating shells and pearls and small coral tufts at the corners instead of petals, seabed stones at the far left and right. """ + PALETTE_REF),
  dict(out="skin_bench.png", refs=["game_bench_sakura.png", "game_bench_ice.png", "game_bench_nightwisp.png"],
       body="""The 'bench' layer of a board skin. Attached images are the same layer from three existing skins: a 16:9 canvas, fully transparent except one long low stone bench in the upper part, seen from a high front angle, containing exactly 8 octagonal slot tiles in a single row, with small theme decoration at both ends. Reproduce exactly the same position, size, perspective and the 8 equal slots. New look: bench frame of pale sand-coloured seabed stone with a champagne-gold rim, slot tiles of smooth pearl-white / pale aqua mother-of-pearl, both ends decorated with pink coral, a scallop shell, pearls and a little seaweed."""),
  dict(out="skin_carrot.png", refs=["game_carrot_sakura.png", "game_carrot_ice.png", "game_carrot_nightwisp.png", "concept_shell.png"],
       body="""The harvest object of a board skin. Attached images 1-3 are the same object from three existing skins (a big carrot standing on a small ring of stones, portrait canvas, transparent background). For this skin the carrot is replaced by a big open scallop shell holding one large pearl, standing upright on the same kind of small ring of seabed stones, same overall height, same footprint and same position in the canvas as the carrots, with two small pink coral branches and seaweed behind it where the carrot leaves were. Portrait canvas with the same aspect ratio as the references, fully transparent background, no ground shadow. """ + PALETTE_REF),
  dict(out="skin_shop_panel.png", refs=["game_shop_panel_sakura.png", "game_shop_panel_ice.png", "game_shop_panel_nightwisp.png", "../samples/shop_button_coral_v1.png"],
       body="""The shop panel of a board skin. Attached images 1-3 are the same panel from three existing skins: a wide horizontal unrolled scroll, a large calm empty area in the middle (text and cards are drawn on it by the game), a vertical roller with finials at the left and right ends, small theme decoration only at the corners. Reproduce the same shape, aspect ratio and empty centre. Image 4 is the matching shop button of this ocean skin: use the same materials. New look: paper area in pale pearl-white with a very faint aqua wave tint, rollers in sea blue with champagne-gold finials, corners decorated with small coral, shells, pearls and seaweed. Fully transparent background."""),
  frame("pearl_shell", "the simplest, entry-level frame of the set: slim pearl-white and pale shell-pink ring made of overlapping small scallop shells, four anchor points are small white pearls, a few tiny bubbles, almost no gold."),
  frame("sea_king", "the most prestigious frame of the set: thick champagne-gold ring with a deep-blue inlay, a crown-like crest at the top made of a large scallop shell flanked by two rising waves, large pearls at the other three anchor points, coral branches and strings of small pearls hanging at the lower sides."),
  pet("hermit_crab", "concept_crab.png", "a cute orange-red hermit crab living in a pink-lavender spiral shell decorated with a starfish and coral, big claws, holding a small shell lantern with a glowing pearl in one claw."),
  pet("seahorse", "concept_seahorse.png", "a cute peach-orange seahorse with turquoise fins and a curled tail, a coral sprig and starfish on its head, wearing a pearl necklace, holding a small coral-branch staff with a pearl on top."),
  pet("shell_turtle", "concept_turtle.png", "a cute pale-blue baby sea turtle whose shell is a pink-lavender scallop shell decorated with coral and a starfish, holding a small shell lantern with a glowing pearl in one flipper."),
  pet("manta", "concept_manta.png", "a cute baby manta ray, lavender-blue on top and pearl-white underneath, small smiling face, wing fins spread as if gliding, a shell-and-coral ornament on its head, a small pearl lantern hanging from its tail."),
  dict(out="bg_coral_palace.png", refs=["game_bg_altar.png", "game_bg_sakura_wish.png", "concept_board.png"],
       body="""A wide 16:9 background illustration. Attached images 1-2 are existing backgrounds of my game: match their painterly anime background style, depth layering, warm lantern light accents and composition (a calm open stage area in the lower centre where UI or a character will be placed, framing elements at the left and right). Scene: an undersea coral kingdom plaza: a round pale stone dais with a shell motif in the centre foreground, big pink and orange corals and seaweed framing both sides, a small shell-shaped cottage with warm lit windows, ruined pale stone arches and a distant coral palace in soft blue haze, light rays from the surface, a few bubbles, shell lanterns with warm pearl light. No characters. This one is NOT transparent: full painted scene. """ + PALETTE_REF),
  dict(out="ui_title_plaque.png", refs=["game_ui_banner_ranked.png", "game_ui_banner_win.png", "../samples/shop_button_coral_v1.png"],
       body="""A title plaque for a game menu page. Attached images 1-2 are existing title banners of my game: a wide horizontal parchment ribbon with curled scroll ends and gold trim, an emblem on top centre, an empty calm middle where the game draws the title text. Reproduce that shape language and empty middle. Image 3 shows the ocean materials to use. New look: ribbon in pale pearl parchment with a sea-blue border band, champagne-gold trim, top emblem is a scallop shell with a pearl between two small coral branches instead of leaves. Wide canvas about 3:1, fully transparent background."""),
  dict(out="ui_reward_card.png", refs=["game_ui_card_rare.png", "game_ui_card_epic.png"],
       body="""A reward slot card frame for a battle-pass track. Attached images are existing item card frames of my game: a square-ish frame with a carved border, an empty transparent window in the middle where the item icon goes, a small empty label plate at the bottom, a round badge at the top right corner. Reproduce the same structure, proportions, empty transparent window and empty plate. New look: border of pale seabed stone with champagne-gold edge and sea-blue inlay, small coral and seaweed growing at the lower corners, a pearl in the round badge, a tiny scallop shell at the top centre. Fully transparent background and transparent window."""),
 ],
 "B": [
  emote("seahorse_like", "seahorse", "concept_emote_seahorse_like.png", "winking, big smile, giving a thumbs-up with one fin, a couple of bubbles, small yellow accent lines."),
  emote("jellyfish_help", "jellyfish", "concept_emote_jelly_cry.png", "panicking and crying for help, eyes squeezed shut with big tears, mouth wide open, tentacles flailing, motion lines."),
  emote("turtle_nice", "shell_turtle", None, "cheering 'nice!': both front flippers raised high, sparkling eyes, open happy mouth, small bubbles popping around."),
  emote("crab_rally", "hermit_crab", None, "calling teammates to gather: one claw raised high waving, the other pointing forward, determined happy face, small yellow accent lines."),
  emote("manta_smirk", "manta", None, "mischievous smirk: half-closed sly eyes, one side of the mouth raised, fins slightly curled up."),
  dict(out="memorial_card.png", refs=["../samples/pet_jellyfish_coral_v1.png", "../samples/bg_coral_palace.png", "../samples/avatar_frame_sea_king_v1.png"],
       body="""A vertical collectible season memorial card (portrait 2:3). Image 1 is the featured character: keep exactly this bubble jellyfish (colours, cape, shell ornament, shell lantern) floating happily in the centre. Image 2 is the scene to use behind it (coral kingdom plaza, light rays). Image 3 shows the material language for the card border. The card has an ornate border of champagne gold and pearl-white with a scallop-shell crest at the top centre, pearls at the four corners, coral sprigs at the lower corners, and an EMPTY pale ribbon plate at the bottom (the game draws the title there). Rounded card corners, fully transparent background outside the card."""),
  dict(out="key_art.png", refs=["../samples/pet_jellyfish_coral_v1.png", "../samples/pet_hermit_crab_coral_v1.png", "../samples/pet_seahorse_coral_v1.png", "../samples/pet_shell_turtle_coral_v1.png", "../samples/pet_manta_coral_v1.png", "../samples/bg_coral_palace.png"],
       body="""A wide 16:9 season key-art illustration with no text. Images 1-5 are the five ocean pets of the season: draw all five exactly as designed (same colours, capes and props), with the bubble jellyfish largest in the centre, the hermit crab and shell turtle on the seabed at left and right, the seahorse and the manta ray swimming above. Image 6 is the scene: the coral kingdom plaza. Leave the top quarter relatively calm (the game draws the season title there) and the bottom strip calm for a button. Full painted scene, not transparent."""),
 ],
}

def run(job):
    out = os.path.join(HERE, "samples", job["out"])
    name = job["out"][:-4]
    if os.path.exists(out):
        return name, "exists"
    prompt = (f"Use your built-in image generation tool to create ONE new image, then save the resulting PNG as `samples/{job['out']}` in the current directory. "
              "Generate it with the image tool, do not draw it with code. Do not modify any other file. If the saved image should have a transparent background, make sure the PNG really has an alpha channel.\n\n"
              + job["body"] + "\n\n" + STYLE + "\n\nWhen done, reply with only the saved file path and the pixel size.")
    cmd = ["cmd", "/c", CODEX, "exec", "-m", MODEL, "--skip-git-repo-check", "--sandbox", "workspace-write"]
    for r in job["refs"]:
        cmd += ["-i", os.path.normpath(os.path.join(HERE, "refs", r))]
    cmd.append("-")
    os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
    for attempt in (1, 2):
        with open(os.path.join(HERE, "logs", name + ".log"), "w", encoding="utf-8") as log:
            try:
                p = subprocess.run(cmd, input=prompt.encode("utf-8"), stdout=log, stderr=subprocess.STDOUT, cwd=HERE, timeout=900)
                rc = p.returncode
            except subprocess.TimeoutExpired:
                rc = "timeout"
        if os.path.exists(out):
            return name, f"ok (try {attempt})"
    return name, f"FAILED rc={rc}"

if __name__ == "__main__":
    jobs = JOBS[sys.argv[1]]
    if len(sys.argv) > 2:
        jobs = [j for j in jobs if j["out"][:-4] in sys.argv[2:]]
    with ThreadPoolExecutor(4) as ex:
        for name, status in ex.map(run, jobs):
            print(name, status, flush=True)
