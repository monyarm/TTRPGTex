use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname);

# Shared defaults for TTRPG LuaLaTeX projects.
$pdf_mode = 4;  # Use lualatex
$out_dir = "build";
@default_files = ('main.tex');

my $ttrpg_lib_dir = dirname(abs_path(__FILE__));
ensure_path('TEXINPUTS', $ttrpg_lib_dir . '//');

# Dependency tracking is handled by the Lua code forcing each JSON/CSV read
# through TeX's native input streams, which latexmk records in the .fls file.

1;