const fs = require('fs');
const path = require('path');

const file = path.join('C:', 'Users', 'HB', '.openclaw', 'workspace', 'fund_app_flutter', 'lib', 'main.dart');
let content = fs.readFileSync(file, 'utf8');

// Find the fetchHoldings regex pattern line with raw string [\'"]
const lines = content.split('\n');
let replaced = false;

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  if (line.includes("r'<tr.*?>") && line.includes("tor")) {
    console.log('Found raw regex at line ' + (i+1) + ': ' + line.trim());
    // Replace the raw string with a triple-quoted const pattern
    lines[i] = "      const pattern = '''<tr.*?><td.*?>\\d+</td><td.*?><a[^>]*>(\\d{6})</a></td><td.*?><a[^>]*>([^<]+)</a></td>.*?<td[^>]*class=[\"']tor[\"']>([\\d\\.]+)%''';";
    // Check next line for dotAll, replace with RegExp(pattern)
    if (i + 1 < lines.length && lines[i+1].includes('dotAll')) {
      lines[i+1] = '      final reg = RegExp(pattern, dotAll: true);';
    }
    replaced = true;
    console.log('Replaced with triple-quoted pattern');
    break;
  }
}

if (!replaced) {
  console.log('No raw regex found - might already be triple-quoted');
}

fs.writeFileSync(file, lines.join('\n'), 'utf8');
console.log('File written');
