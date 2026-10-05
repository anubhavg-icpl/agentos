# heygen-com/hyperframes: skills for making video as HTML ("HyperFrames"):
# the composition contract, animation and keyframes, audio, captions, a media
# resolver, and ready workflows (product launch video, PR to video, faceless
# explainer, slideshow, motion graphics, Figma import, Remotion port; the
# talking-head and music-video workflows are not shipped, see below).
#
# Only skills/ is used. Left out:
#   - registry/ (catalogue blocks, examples), examples/, themes/, and .claude/
#     and .agents/ (the repository's own development skills: changelog-video,
#     cut-the-curve, motion-doctrine, ...)
#   - talking-head-recut and music-to-video: each bundles gsap.min.js
#     (GreenSock, "All rights reserved", GSAP Standard License), which is not
#     a licence that clearly allows redistribution
#   - media-use/audio/assets/sfx/*.mp3 (19 Pixabay sound effects, Pixabay
#     Content License, which does not allow redistributing the files on their
#     own); the rest of media-use is kept
# Licence: Apache-2.0.
{ mkSkillPack, sources, discover }:

let
  src = sources.hyperframes;
in
mkSkillPack {
  pack = "hyperframes";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.renameSkills {
    pack = "hyperframes";
    inherit src;
    skills = discover.findSkills {
      inherit src;
      exclude = [ "talking-head-recut" "music-to-video" ];
    };
    rename.media-use = "media-use"; # copied to drop its sound-effect files
    prune = [ "media-use/audio/assets/sfx/*.mp3" ];
  };
  description = "Video as HTML: HyperFrames composition, animation, audio, captions, and workflows for launch videos, PR videos, explainers";
  homepage = "https://github.com/heygen-com/hyperframes";
  license = "Apache-2.0";
  collections = [ "design" ];
  defaultEnable = false;
  notes = ''
    The skills drive upstream's CLI with `npx hyperframes ...`: it is downloaded from the npm registry when first run (network, Node 22 or newer) and rendering needs FFmpeg and a Chromium; none of these are provided by the pack.
    Several workflows can use HeyGen (HEYGEN_API_KEY or a HeyGen login) for generated voice, music or avatars, and ElevenLabs or Google (GEMINI) keys for text-to-speech and images; local alternatives (kokoro-onnx, parakeet-mlx, whisper) are named in the skills. Python helpers exist in embedded-captions, hyperframes-creative, media-use and remotion-to-hyperframes; Node scripts in most skills.
    Skills refer to each other and to files in the upstream repository (registry/, docs/); the sibling skills are in the pack, the repository files are not.
    Not shipped: talking-head-recut and music-to-video, because they bundle GSAP (gsap.min.js, GreenSock Standard License, all rights reserved) and the skills that mention them (general-video, hyperframes) still name them.
    The sound-effect library of media-use (media-use/audio/assets/sfx/*.mp3, Pixabay Content License) is removed because that licence does not allow redistributing the files as such; its manifest.json and CREDITS.md remain, and the skill retrieves sound effects online instead.
    19 skills: expect noticeable context use when enabled.
  '';
}
