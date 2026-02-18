<?php
// Auto-generates Lua package index by scanning packages/ tree.
// No static PKGLIST needed — always fresh.

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: public, max-age=60');

$pkgdir = $_SERVER['DOCUMENT_ROOT'] . '/packages';

$categories = [
    'drivers'    => ['dest' => '/drivers/',       'strip' => '.sys'],
    'executable' => ['dest' => '/usr/commands/',   'strip' => ''],
    'modules'    => ['dest' => '/lib/',            'strip' => ''],
    'multilib'   => ['dest' => '/usr/lib/',        'strip' => ''],
];

function scanPkgs($dir, $cat, $info, $sub = '') {
    $out = [];
    if (!is_dir($dir)) return $out;
    foreach (scandir($dir) as $f) {
        if ($f[0] === '.' || $f === 'index.html') continue;
        $full = "$dir/$f";
        if (is_dir($full)) {
            $out = array_merge($out, scanPkgs($full, $cat, $info, $sub ? "$sub/$f" : $f));
        } else {
            $name = pathinfo($f, PATHINFO_FILENAME);
            if ($info['strip'] && str_ends_with($name, $info['strip']))
                $name = substr($name, 0, -strlen($info['strip']));
            $relUrl = "packages/$cat" . ($sub ? "/$sub" : '') . "/$f";
            
            // Try to extract description from first comment line
            $desc = '';
            $handle = fopen($full, 'r');
            if ($handle) {
                $first = fgets($handle); $second = fgets($handle);
                fclose($handle);
                // Lua: "-- description here" on line 1 or 2
                foreach ([$first, $second] as $line) {
                    if ($line && preg_match('/^--\s*(.{5,80})/', trim($line), $m)) {
                        $candidate = trim($m[1]);
                        // Skip shebangs, file paths, blank descriptions
                        if (!str_starts_with($candidate, '/') && !str_starts_with($candidate, '!')) {
                            $desc = $candidate; break;
                        }
                    }
                }
            }
            
            $out[] = compact('name', 'cat', 'desc') + [
                'file' => $f,
                'dest' => $info['dest'],
                'url'  => $relUrl,
                'size' => filesize($full),
                'sub'  => $sub ?: null,
                'mtime'=> filemtime($full),
            ];
        }
    }
    return $out;
}

$all = [];
foreach ($categories as $cat => $info)
    $all = array_merge($all, scanPkgs("$pkgdir/$cat", $cat, $info));

// Sort: drivers first, then by name
usort($all, function($a, $b) {
    $order = ['drivers'=>0, 'modules'=>1, 'multilib'=>2, 'executable'=>3];
    $ca = $order[$a['cat']] ?? 9;
    $cb = $order[$b['cat']] ?? 9;
    return $ca !== $cb ? $ca - $cb : strcmp($a['name'], $b['name']);
});

echo "-- xpm package index (auto-generated)\n";
echo "-- " . gmdate('Y-m-d H:i:s') . " UTC | " . count($all) . " packages\n";
echo "return {\n";
foreach ($all as $p) {
    $sub  = $p['sub']  ? sprintf(',sub="%s"',  addslashes($p['sub']))  : '';
    $desc = $p['desc'] ? sprintf(',desc="%s"',  addslashes($p['desc'])) : '';
    printf('  {name="%s",file="%s",cat="%s",dest="%s",url="%s",size=%d,mtime=%d%s%s},' . "\n",
        addslashes($p['name']), addslashes($p['file']),
        $p['cat'], $p['dest'], addslashes($p['url']),
        $p['size'], $p['mtime'], $sub, $desc);
}
echo "}\n";