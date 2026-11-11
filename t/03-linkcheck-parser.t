use v5.42;
use utf8::all;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/../lib";

use LinkCheck::Role::Parser;

# The regex fallback finds attributes in markup, not in the code of an inline script or style: an assignment like
# `let data = JSON.parse(...)` once came out as the link "JSON.parse($(".
my $scan = \&LinkCheck::Role::Parser::_scan_html_for_urls;

my $html = <<~'HTML';
  <p><a href="/one">one</a> <img src='/two.png'> <object data=/three.svg></object></p>
  <script type="application/json" id="d">{"href": "/not-a-link"}</script>
  <script src="/four.js"></script>
  <script>
    let data = JSON.parse($('d').textContent);
    el.href = '/also-not';
    const src = "/nor-this";
  </script>
  <style>.x { background: url(/five.png); } a[href="/sel"] { color: red }</style>
  <a href="/six">six</a>
  HTML

is_deeply [ $scan->($html) ], [ '/one', '/two.png', '/three.svg', '/four.js', '/six' ],
  'attributes in the markup, a script\'s src among them; nothing from inside a script or style';

is_deeply [ $scan->('<SCRIPT>x.src = "/a";</SCRIPT ><a href="/b">') ], ['/b'],
  'whatever the case of the tag, and a space before its close';

is_deeply [ $scan->('<script>unclosed href="/c"') ], ['/c'],
  'an unclosed script is left as it is (nothing to strip to)';

done_testing;
