# nexu-io/open-design: only the few user-facing, generic skills of the
# project's skills/ directory. The repository is mostly the Open Design
# application plus catalogues, which are left out on purpose:
#   - 85 catalogue stubs in skills/ ("This catalogue entry advertises the
#     skill ..."): pointers to other projects' skills, no instructions
#   - skills/ entries that are renderable templates or example decks, cards and
#     video frames (mode prototype, deck, video or template: article-magazine,
#     card-*, deck-*, frame-*, social-*, *-template, ...) and design-templates/:
#     they need the Open Design renderer
#   - copies of third-party skills (taste-skill family by Leonxlnx: shipped by
#     the taste-skill pack; Anthropic's frontend-design; Emil Kowalski's,
#     Vercel's, GreenSock's gsap-*, OpenAI's hatch-pet, impeccable-design-polish)
#   - skills tied to the Open Design app: library-curator (OD Library),
#     od-next-media-inputs (OD Next plan), brand-extract (in-app browser)
#   - plugins/ (_official, community, spec): the application's plugin catalogue
#   - .claude/ and tests/ fixtures
# Kept: skills with `mode: utility | design | design-system | image` that are
# the project's own (no third-party upstream), plus web-clone (its own MIT
# LICENSE). Licence: Apache-2.0 (root LICENSE).
{ lib, mkSkillPack, sources, discover }:

let
  src = sources.open-design;
  has = needle: text: lib.hasInfix needle text;
  # the project's own functional skills
  own = _dir: text:
    !(has "catalogue entry advertises" text)
    && !(has "upstream:" text && !(has "nexu-io" text))
    && (lib.any (m: has "mode: ${m}\n" text) [ "utility" "design" "design-system" "image" ]);
in
mkSkillPack {
  pack = "open-design";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    filter = own;
    include = [ "web-clone" ];
    exclude = [ "library-curator" "od-next-media-inputs" "brand-extract" ];
  };
  description = "Open Design's own generic skills: design brief, reference-to-DESIGN.md contract, website clone method, chat motion overlay, PPTX fidelity audit";
  homepage = "https://github.com/nexu-io/open-design";
  license = "Apache-2.0";
  collections = [ "community" "design" ];
  defaultEnable = false;
  notes = ''
    A small selection from a large repository (see the header of packs/open-design.nix for what is left out and why): most of the 160 skills there are catalogue pointers, renderable templates for the Open Design app, or copies of other projects' skills.
    web-clone has its own MIT licence (the rest is the repository's Apache-2.0); its text is mostly Chinese, as is part of chat-motion-overlay. ecommerce-image-workflow needs reference product photos and an agent with image generation; pptx-html-fidelity-audit expects a python-pptx export and Python; pr-feedback-quality-gate works with pull request comments (gh and git). Nothing here needs the Open Design application, but some skills mention its features.
  '';
}
