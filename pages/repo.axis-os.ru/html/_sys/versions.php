<?php
header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: public, max-age=120');

$osdir = '/var/www/repo.axis-os.ru/html/os';

function scanVersions($dir, $subdir) {
    $out = [];
    if (!is_dir($dir)) return $out;
    foreach (scandir($dir, SCANDIR_SORT_DESCENDING) as $f) {
        if ($f[0] === '.' || $f === 'index.html') continue;
        $full = "$dir/$f";
        if (!is_dir($full)) continue;
        if (!is_dir("$full/$subdir")) continue;
        $mtime = filemtime($full);
        $label = $f;
        if (file_exists("$full/VERSION"))
            $label = trim(file_get_contents("$full/VERSION"));

        // Scan EEPROM variants
        $variants = [];
        $eepDir = "$full/eeprom";
        if (is_dir($eepDir)) {
            foreach (scandir($eepDir) as $ef) {
                if ($ef[0] === '.' || !str_ends_with($ef, '.lua')) continue;
                $eName = pathinfo($ef, PATHINFO_FILENAME);

                // Extract human-readable info from first comment
                $eDesc = $eName;
                $eFull = "$eepDir/$ef";
                $eh = fopen($eFull, 'r');
                if ($eh) {
                    $line1 = fgets($eh); $line2 = fgets($eh);
                    fclose($eh);
                    foreach ([$line1, $line2] as $line) {
                        if ($line && preg_match('/^--\s*(.{5,80})/', trim($line), $m)) {
                            $eDesc = trim($m[1]); break;
                        }
                    }
                }

                // Detect features from filename
                $secure = (strpos($ef, 'secure') !== false);
                $axfs   = (strpos($ef, 'axfs') !== false);
                $managed = !$axfs;

                $variants[] = [
                    'file'    => $ef,
                    'name'    => $eName,
                    'desc'    => $eDesc,
                    'secure'  => $secure,
                    'axfs'    => $axfs,
                    'managed' => $managed,
                    'size'    => filesize($eFull),
                ];
            }
        }

        $out[] = ['id' => $f, 'label' => $label, 'mtime' => $mtime, 'variants' => $variants];
    }
    return $out;
}

$kernels = scanVersions($osdir, 'kernel');
$eeproms = scanVersions($osdir, 'eeprom');

$kLatest = count($kernels) > 0 ? $kernels[0]['id'] : 'unknown';
$eLatest = count($eeproms) > 0 ? $eeproms[0]['id'] : 'unknown';
if (file_exists("$osdir/LATEST_KERNEL")) $kLatest = trim(file_get_contents("$osdir/LATEST_KERNEL"));
if (file_exists("$osdir/LATEST_EEPROM")) $eLatest = trim(file_get_contents("$osdir/LATEST_EEPROM"));

echo "-- AxisOS version index (auto-generated)\n";
echo "return {\n";
echo "  kernel_latest=\"$kLatest\",\n";
echo "  eeprom_latest=\"$eLatest\",\n";
echo "  kernels={\n";
foreach ($kernels as $v) {
    printf("    {id=\"%s\",label=\"%s\",mtime=%d},\n",
        addslashes($v['id']), addslashes($v['label']), $v['mtime']);
}
echo "  },\n";
echo "  eeproms={\n";
foreach ($eeproms as $v) {
    printf("    {id=\"%s\",label=\"%s\",mtime=%d,variants={\n",
        addslashes($v['id']), addslashes($v['label']), $v['mtime']);
    foreach ($v['variants'] as $ev) {
        printf("      {file=\"%s\",name=\"%s\",desc=\"%s\",secure=%s,axfs=%s,managed=%s,size=%d},\n",
            addslashes($ev['file']), addslashes($ev['name']),
            addslashes($ev['desc']),
            $ev['secure'] ? 'true' : 'false',
            $ev['axfs'] ? 'true' : 'false',
            $ev['managed'] ? 'true' : 'false',
            $ev['size']);
    }
    echo "    }},\n";
}
echo "  },\n";
echo "}\n";