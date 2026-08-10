# swaybar example — stylesheet. Gruvbox palette + Iosevka, matching the colours
# in ~/.config/scroll/config's `bar { colors { ... } }` block:
#   background #0e1418, statusline #ebdbb2, and the gruvbox accents used per
#   module in the shell script (#cc241d red, #d79921 yellow, #689d6a green,
#   #458588 blue, #b16286 purple).
glob CSS: str = """
.bar {
    background: #0e1418;
    color: #ebdbb2;
    font-family: Iosevka, monospace;
    font-size: 18px;
}
.bar-inner {
    min-height: 34px;
    padding: 2px 12px;
}
.bar-inner > * { padding: 2px 10px; }
.clock { font-weight: bold; color: #ebdbb2; }
.countdown { color: #d79921; }
.stocks { color: #b16286; }
.mem { color: #458588; }
.bt { color: #689d6a; }
.battery { color: #d79921; }
.battery.low { color: #cc241d; }
.spacer { }
""";
