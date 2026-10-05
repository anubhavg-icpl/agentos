# K-Dense-AI/scientific-agent-skills: scientific and financial research
# skills: bioinformatics (Biopython, scanpy, scvi-tools, PyDESeq2, ...),
# chemistry and drug discovery, materials, clinical and medical, data analysis
# and plotting, database lookups (PubChem, UniProt, ChEMBL, ClinicalTrials.gov,
# FRED, ...), literature search, scientific writing and slides.
#
# Licence: MIT (LICENSE.md, K-Dense Inc.). Each skill's front matter has a
# `license:` field that usually names the licence of the software it documents
# (BSD, Apache, GPL, ...). Left out, because the field names terms that do not
# plainly allow redistribution or is unknown:
#   - deepspot-m (PolyForm-Noncommercial-1.0.0)
#   - what-if-oracle (CC BY-NC-SA 4.0)
#   - rowan (Proprietary, API key required)
#   - glycoengineering, phylogenetics, primekg (license: Unknown)
# GPL-licensed ones (bioservices, cobrapy, etetoolkit) and CC-BY ones (bids,
# depmap) permit redistribution and are kept.
{ mkSkillPack, sources, discover }:

let
  src = sources.scientific-skills;
in
mkSkillPack {
  pack = "scientific-skills";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    exclude = [
      "deepspot-m"
      "what-if-oracle"
      "rowan"
      "glycoengineering"
      "phylogenetics"
      "primekg"
    ];
  };
  description = "Scientific and financial research skills: bioinformatics, chemistry, clinical, data analysis, database lookups, scientific writing";
  homepage = "https://github.com/K-Dense-AI/scientific-agent-skills";
  license = "MIT";
  collections = [ "science" "large" ];
  defaultEnable = false;
  notes = ''
    About 170 skills: enabling the pack adds roughly 17k tokens of skill descriptions to every session; enable it where you do scientific work.
    The skills are instructions for Python (and some R/CLI) packages and public databases. None of the packages are installed; the agent is expected to pip install what it needs (uv is the upstream convention), so most skills need Python and the network. Many database skills use public APIs, some need free or paid API keys (for example FRED, DrugBank, Materials Project). Many skills carry Python scripts (about 530 files) that are shipped as they are.
    The skills' own `license:` lines usually name the licence of the software the skill documents (GPL for bioservices, cobrapy and etetoolkit; CC-BY for bids and depmap). They are kept because those licences permit redistribution.
    Six skills are not shipped: deepspot-m (PolyForm Noncommercial), what-if-oracle (CC BY-NC-SA), rowan (proprietary), glycoengineering, phylogenetics and primekg (licence unknown).
  '';
}
