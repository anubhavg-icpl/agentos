# ═══════════════════════════════════════════════════════════════════════
# AgentOS Browser Tools Module
# ═══════════════════════════════════════════════════════════════════════
#
# Headless browser automation for agents that need to interact with
# web pages, scrape content, or test web apps.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.browser-tools;
in
{
  options.agentos.browser-tools = {
    enable = lib.mkEnableOption "AgentOS browser automation tools";

    enableChromium = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install headless Chromium";
    };

    enableFirefox = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install headless Firefox (disabled: larger)";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      # Headless browsers
      chromium         # headless mode: chromium --headless --dump-dom
      firefox          # headless: firefox --headless

      # Browser automation frameworks
      playwright-driver # modern browser automation
      puppeteer-cli    # headless Chrome Node API
      selenium-server-standalone

      # Web scraping tools
      wget
      curl
      httpie
      pup              # HTML processor
      htmlq            # jq for HTML
      xq               # XML processor

      # Content extraction
      mermaid-cli      # diagram rendering
      pandoc           # document conversion
      poppler-utils    # PDF tools (pdftotext, etc)
      imagemagick      # image manipulation
      ffmpeg           # video processing
      yt-dlp           # video downloader

      # Web testing
      cypress          # e2e testing
      k6               # load testing

      # ── Browser CLI tool ───────────────────────────────────────────
      (pkgs.writeShellScriptBin "agentos-web" ''
        #!/usr/bin/env bash
        set -euo pipefail

        case "''${1:-help}" in
          fetch)
            URL="''${2:-}"
            [ -z "$URL" ] && { echo "Usage: agentos-web fetch <url>"; exit 1; }
            ${pkgs.curl}/bin/curl -sL "$URL"
            ;;
          text)
            # Fetch a URL and extract text content
            URL="''${2:-}"
            [ -z "$URL" ] && { echo "Usage: agentos-web text <url>"; exit 1; }
            ${pkgs.curl}/bin/curl -sL "$URL" | ${pkgs.pup}/bin/pup 'text{}'
            ;;
          screenshot)
            URL="''${2:-}"
            OUT="''${3:-screenshot.png}"
            [ -z "$URL" ] && { echo "Usage: agentos-web screenshot <url> [output.png]"; exit 1; }
            ${pkgs.chromium}/bin/chromium --headless --no-sandbox --screenshot="$OUT" --window-size=1920,1080 "$URL"
            echo "Screenshot saved: $OUT"
            ;;
          pdf)
            URL="''${2:-}"
            OUT="''${3:-output.pdf}"
            [ -z "$URL" ] && { echo "Usage: agentos-web pdf <url> [output.pdf]"; exit 1; }
            ${pkgs.chromium}/bin/chromium --headless --no-sandbox --print-to-pdf="$OUT" "$URL"
            echo "PDF saved: $OUT"
            ;;
          render)
            # Render a JS-heavy page with Playwright
            URL="''${2:-}"
            [ -z "$URL" ] && { echo "Usage: agentos-web render <url>"; exit 1; }
            ${pkgs.nodejs_22}/bin/npx playwright-cli screenshot --browser chromium "$URL" rendered.png
            ;;
          search)
            QUERY="''${2:-}"
            [ -z "$QUERY" ] && { echo "Usage: agentos-web search <query>"; exit 1; }
            ${pkgs.curl}/bin/curl -sL "https://html.duckduckgo.com/html/?q=$(echo "$QUERY" | sed 's/ /+/g')" | \
              ${pkgs.pup}/bin/pup '.result__title text{}' | head -10
            ;;
          help|*)
            cat <<'HELP'
        AgentOS Browser Tools

        USAGE:
            agentos-web <COMMAND> [ARGS]

        COMMANDS:
            fetch <url>               Fetch raw HTML
            text <url>                Fetch and extract text content
            screenshot <url> [out]    Take a screenshot
            pdf <url> [out]           Save page as PDF
            render <url>              Render JS-heavy page (Playwright)
            search <query>            Search the web (DuckDuckGo)

        HELP
            ;;
        esac
      '')
    ];
  };
}
