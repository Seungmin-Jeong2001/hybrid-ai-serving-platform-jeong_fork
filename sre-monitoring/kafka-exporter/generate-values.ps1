[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..")
$terraformDir = Join-Path $repoRoot "public\terraform"
$templatePath = Join-Path $scriptDir "values.yaml"
$outputPath = Join-Path $scriptDir "values.generated.yaml"

Write-Host "[1/3] Reading Terraform output msk_bootstrap_brokers..." -ForegroundColor Yellow
$brokersRaw = terraform -chdir="$terraformDir" output -raw msk_bootstrap_brokers

if (-not $brokersRaw) {
  throw "Terraform output 'msk_bootstrap_brokers' is empty."
}

$brokers = $brokersRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }

if ($brokers.Count -eq 0) {
  throw "No Kafka brokers found in Terraform output."
}

$brokerLines = ($brokers | ForEach-Object { "  - $_" }) -join "`r`n"

Write-Host "[2/3] Rendering kafka-exporter values.generated.yaml..." -ForegroundColor Yellow
$template = Get-Content -LiteralPath $templatePath -Raw
$rendered = $template.Replace("{{KAFKA_BROKERS}}", $brokerLines)
Set-Content -LiteralPath $outputPath -Value $rendered -Encoding utf8

Write-Host "[3/3] Done." -ForegroundColor Green
Write-Host "Generated: $outputPath" -ForegroundColor Green
