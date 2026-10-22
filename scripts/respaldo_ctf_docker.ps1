# Respaldo de PostgreSQL y Redis del Docker Compose ORIGINAL en Windows 11.
# No usar en producción cuando las bases estén solo en LAB-DB-POSTGRES.
# Uso: .\respaldo_ctf_docker.ps1 -RutaProyecto "C:\ruta\ctf_project"
param(
  [Parameter(Mandatory = $true)]
  [string]$RutaProyecto,
  [string]$CarpetaRespaldos = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Verificar-Codigo([string]$Paso) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Paso falló con código $LASTEXITCODE. El respaldo NO es válido."
  }
}
if (-not (Test-Path -LiteralPath $RutaProyecto -PathType Container)) {
  throw "No existe la carpeta del proyecto: $RutaProyecto"
}
$RutaProyecto = (Resolve-Path -LiteralPath $RutaProyecto).Path
if (-not (Test-Path -LiteralPath (Join-Path $RutaProyecto 'docker-compose.yml'))) {
  throw "Falta docker-compose.yml en $RutaProyecto"
}
if ([string]::IsNullOrWhiteSpace($CarpetaRespaldos)) {
  $CarpetaRespaldos = Join-Path $HOME 'Respaldos_CTF'
}
New-Item -ItemType Directory -Force -Path $CarpetaRespaldos | Out-Null
$CarpetaRespaldos = (Resolve-Path -LiteralPath $CarpetaRespaldos).Path
$marca = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$salida = Join-Path $CarpetaRespaldos "docker_$marca"
New-Item -ItemType Directory -Path $salida -ErrorAction Stop | Out-Null
$pgId = ''
$redisId = ''
$pgTmp = "/tmp/ctf_backup_$marca.dump"
$redisTmp = "/tmp/ctf_backup_$marca.rdb"

try {
  Push-Location -LiteralPath $RutaProyecto
  try {
    & docker compose -f docker-compose.yml version | Out-Null
    Verificar-Codigo 'Docker Compose'
    $pgId = (& docker compose -f docker-compose.yml ps -q postgres | Out-String).Trim()
    Verificar-Codigo 'Buscar PostgreSQL'
    $redisId = (& docker compose -f docker-compose.yml ps -q redis | Out-String).Trim()
    Verificar-Codigo 'Buscar Redis'
    if ([string]::IsNullOrWhiteSpace($pgId) -or [string]::IsNullOrWhiteSpace($redisId)) {
      throw 'No están ambos contenedores en ejecución. Revisa: docker compose ps'
    }

    Write-Host '1/4 Respaldando PostgreSQL dentro de Docker...'
    & docker exec $pgId sh -ec 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges -f "$1"' sh $pgTmp
    Verificar-Codigo 'pg_dump'
    & docker exec $pgId pg_restore --list $pgTmp | Out-Null
    Verificar-Codigo 'Verificación PostgreSQL'
    $pgLocal = Join-Path $salida 'postgres_ctf.dump'
    & docker cp "${pgId}:$pgTmp" $pgLocal
    Verificar-Codigo 'Copia PostgreSQL'
    if (-not (Test-Path -LiteralPath $pgLocal) -or (Get-Item -LiteralPath $pgLocal).Length -eq 0) {
      throw 'PostgreSQL: archivo vacío o inexistente.'
    }

    Write-Host '2/4 Respaldando Redis dentro de Docker...'
    & docker exec $redisId redis-cli --rdb $redisTmp
    Verificar-Codigo 'Redis RDB'
    & docker exec $redisId redis-check-rdb $redisTmp | Out-Null
    Verificar-Codigo 'Verificación Redis'
    $redisLocal = Join-Path $salida 'redis_ctf.rdb'
    & docker cp "${redisId}:$redisTmp" $redisLocal
    Verificar-Codigo 'Copia Redis'
    if (-not (Test-Path -LiteralPath $redisLocal) -or (Get-Item -LiteralPath $redisLocal).Length -eq 0) {
      throw 'Redis: archivo vacío o inexistente.'
    }

    Write-Host '3/4 Generando huellas SHA256...'
    $lista = @()
    foreach ($archivo in @($pgLocal, $redisLocal)) {
      $hash = Get-FileHash -LiteralPath $archivo -Algorithm SHA256
      $lista += ($hash.Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($archivo))
    }
    $lista | Set-Content -LiteralPath (Join-Path $salida 'SHA256SUMS.txt') -Encoding ASCII
    @(
      "Origen: Docker Compose CTF; fecha UTC: $marca"
      "Proyecto: $RutaProyecto"
      'postgres_ctf.dump: estructura y datos PostgreSQL.'
      'redis_ctf.rdb: todas las bases lógicas de ESTA instancia Redis.'
      'No incluye .env, contraseñas, datos de Guacamole ni respaldo transaccional conjunto.'
    ) | Set-Content -LiteralPath (Join-Path $salida 'LEEME.txt') -Encoding UTF8

    Write-Host '4/4 Respaldo verificado.' -ForegroundColor Green
    Write-Host "RESPALDO COMPLETO: $salida"
    Write-Host 'Guarda una copia fuera de este equipo; nunca la subas a GitHub.'
  }
  finally { Pop-Location }
}
catch {
  Write-Warning $_.Exception.Message
  Write-Warning "El contenido de $salida puede estar incompleto."
  throw
}
finally {
  if (-not [string]::IsNullOrWhiteSpace($pgId)) {
    & docker exec $pgId rm -f $pgTmp 2>$null | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($redisId)) {
    & docker exec $redisId rm -f $redisTmp 2>$null | Out-Null
  }
}
