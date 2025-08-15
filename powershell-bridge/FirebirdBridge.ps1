# FirebirdBridge.ps1
# Interface de Gestión para Vigencias
# PowerShell Bridge optimizado para Firebird y MySQL usando .NET

param(
    [Parameter(Mandatory=$true)]
    [string]$Operation,
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigJson = "{}",
    
    [Parameter(Mandatory=$false)]
    [string]$Query = "",
    
    [Parameter(Mandatory=$false)]
    [string]$Parameters = "[]",
    
    [Parameter(Mandatory=$false)]
    [string]$SourcePath = "",
    
    [Parameter(Mandatory=$false)]
    [string]$DestinationPath = "",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",
    
    [Parameter(Mandatory=$false)]
    [int]$VigenciaDia = 9,
    
    [Parameter(Mandatory=$false)]
    [int]$DiasFacturas = 5,
    
    [Parameter(Mandatory=$false)]
    [string]$PalabrasExcluidas = "[]",
    
    [Parameter(Mandatory=$false)]
    [string]$PalabrasConvenio = "[]",
    
    [Parameter(Mandatory=$false)]
    [string]$PalabrasCicloEscolar = "[]",
    
    [Parameter(Mandatory=$false)]
    [int]$VigenciaConvenio = 90,
    
    [Parameter(Mandatory=$false)]
    [int]$VigenciaCicloEscolar = 365
)

# Configurar encoding para caracteres especiales
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Función para escribir logs
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

# Función para cargar ensamblados .NET
function Load-RequiredAssemblies {
    try {
        $scriptPath = Split-Path -Parent $MyInvocation.ScriptName
        $libsPath = Join-Path $scriptPath "libs"
        
        if (-not (Test-Path $libsPath)) {
            throw "Directorio de librerías no encontrado: $libsPath. Ejecute install_libs.bat primero."
        }
        
        # Cargar ensamblados necesarios en orden específico
        $assemblies = @(
            "System.Runtime.CompilerServices.Unsafe.dll",
            "System.Threading.Tasks.Extensions.dll",
            "System.Text.Json.dll",
            "System.Configuration.ConfigurationManager.dll",
            "FirebirdSql.Data.FirebirdClient.dll",
            "MySql.Data.dll"
        )
        
        $loadedCount = 0
        foreach ($assembly in $assemblies) {
            $assemblyPath = Join-Path $libsPath $assembly
            if (Test-Path $assemblyPath) {
                try {
                    Add-Type -Path $assemblyPath -ErrorAction SilentlyContinue
                    Write-Log "Ensamblado cargado: $assembly" "SUCCESS"
                    $loadedCount++
                } catch {
                    Write-Log "Advertencia cargando $assembly`: $($_.Exception.Message)" "WARN"
                }
            } else {
                Write-Log "Ensamblado no encontrado: $assembly" "WARN"
            }
        }
        
        if ($loadedCount -lt 3) {
            throw "No se pudieron cargar suficientes ensamblados críticos. Cargados: $loadedCount"
        }
        
        Write-Log "Ensamblados cargados exitosamente: $loadedCount/$($assemblies.Count)" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Error cargando ensamblados: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Función para construir cadena de conexión Firebird
function Build-FirebirdConnectionString {
    param([PSCustomObject]$Config)
    
    try {
        $builder = New-Object FirebirdSql.Data.FirebirdClient.FbConnectionStringBuilder
        $builder.DataSource = $Config.host
        $builder.Port = [int]$Config.port
        $builder.Database = $Config.database
        $builder.UserID = $Config.user
        $builder.Password = $Config.password
        $builder.ServerType = [FirebirdSql.Data.FirebirdClient.FbServerType]::Default
        $builder.Charset = if ($Config.charset) { $Config.charset } else { "UTF8" }
        $builder.Pooling = $false
        $builder.ConnectionTimeout = 120  # Aumentado a 2 minutos
        $builder.CommandTimeout = 300     # Aumentado a 5 minutos
        $builder.Dialect = 3
        
        return $builder.ToString()
    }
    catch {
        throw "Error construyendo cadena de conexión Firebird: $($_.Exception.Message)"
    }
}

# Función para construir cadena de conexión MySQL
function Build-MySQLConnectionString {
    param([PSCustomObject]$Config)
    
    try {
        $connectionString = "Server=$($Config.host);Port=$($Config.port);Database=$($Config.database);Uid=$($Config.user);Pwd=$($Config.password);CharSet=utf8mb4;ConnectionTimeout=120;CommandTimeout=300;AllowUserVariables=True;UseAffectedRows=False;"
        return $connectionString
    }
    catch {
        throw "Error construyendo cadena de conexión MySQL: $($_.Exception.Message)"
    }
}

# Función para probar conexión Firebird
function Test-FirebirdConnection {
    param([PSCustomObject]$Config)
    
    $startTime = Get-Date
    
    try {
        Write-Log "Probando conexión Firebird a $($Config.host):$($Config.port)"
        
        # Validar configuración
        if (-not $Config.database -or $Config.database.Trim() -eq "") {
            throw "Ruta de base de datos es requerida"
        }
        
        # Verificar archivo de base de datos si es local
        if ($Config.host -eq "localhost" -or $Config.host -eq "127.0.0.1" -or $Config.host -eq "") {
            if (-not (Test-Path $Config.database)) {
                throw "Archivo de base de datos no encontrado: $($Config.database)"
            }
        }
        
        $connectionString = Build-FirebirdConnectionString -Config $Config
        
        $connection = New-Object FirebirdSql.Data.FirebirdClient.FbConnection($connectionString)
        $connection.Open()
        
        if ($connection.State -eq [System.Data.ConnectionState]::Open) {
            $command = New-Object FirebirdSql.Data.FirebirdClient.FbCommand("SELECT CURRENT_TIMESTAMP FROM RDB`$DATABASE", $connection)
            $result = $command.ExecuteScalar()
            
            $connection.Close()
            
            $elapsed = (Get-Date) - $startTime
            Write-Log "Conexión Firebird exitosa en $($elapsed.TotalMilliseconds)ms - Tiempo servidor: $result" "SUCCESS"
            
            return @{
                success = $true
                server_time = $result.ToString()
                execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
                method = "PowerShell"
            }
        }
        else {
            throw "Conexión falló - Estado: $($connection.State)"
        }
    }
    catch {
        $elapsed = (Get-Date) - $startTime
        $errorMsg = $_.Exception.Message
        Write-Log "Conexión Firebird falló después de $($elapsed.TotalMilliseconds)ms: $errorMsg" "ERROR"
        
        return @{
            success = $false
            error = $errorMsg
            execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
            method = "PowerShell"
        }
    }
}

# Función para probar conexión MySQL
function Test-MySQLConnection {
    param([PSCustomObject]$Config)
    
    $startTime = Get-Date
    
    try {
        Write-Log "Probando conexión MySQL a $($Config.host):$($Config.port)"
        
        $connectionString = Build-MySQLConnectionString -Config $Config
        
        $connection = New-Object MySql.Data.MySqlClient.MySqlConnection($connectionString)
        $connection.Open()
        
        if ($connection.State -eq [System.Data.ConnectionState]::Open) {
            $command = New-Object MySql.Data.MySqlClient.MySqlCommand("SELECT NOW() as server_time", $connection)
            $result = $command.ExecuteScalar()
            
            $connection.Close()
            
            $elapsed = (Get-Date) - $startTime
            Write-Log "Conexión MySQL exitosa en $($elapsed.TotalMilliseconds)ms - Tiempo servidor: $result" "SUCCESS"
            
            return @{
                success = $true
                server_time = $result.ToString()
                execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
                method = "PowerShell"
            }
        }
        else {
            throw "Conexión falló - Estado: $($connection.State)"
        }
    }
    catch {
        $elapsed = (Get-Date) - $startTime
        $errorMsg = $_.Exception.Message
        Write-Log "Conexión MySQL falló después de $($elapsed.TotalMilliseconds)ms: $errorMsg" "ERROR"
        
        return @{
            success = $false
            error = $errorMsg
            execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
            method = "PowerShell"
        }
    }
}

# Función para copiar base de datos usando Robocopy
function Copy-Database {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    
    $startTime = Get-Date
    
    try {
        Write-Log "Copiando base de datos de $SourcePath a $DestinationPath"
        
        # Validar archivo origen
        if (-not (Test-Path $SourcePath)) {
            throw "Archivo origen no encontrado: $SourcePath"
        }
        
        # Obtener información del archivo origen
        $sourceFile = Get-Item $SourcePath
        $sourceDir = $sourceFile.DirectoryName
        $fileName = $sourceFile.Name
        
        # Crear directorio destino si no existe
        $destDir = Split-Path -Parent $DestinationPath
        if ($destDir -and -not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            Write-Log "Directorio destino creado: $destDir" "SUCCESS"
        }
        
        # Usar Robocopy para copia robusta
        Write-Log "Usando Robocopy para copia robusta..."
        
        $robocopyArgs = @(
            "`"$sourceDir`"",           # Directorio origen
            "`"$destDir`"",             # Directorio destino
            "`"$fileName`"",            # Archivo específico
            "/R:3",                     # 3 reintentos
            "/W:5",                     # 5 segundos entre reintentos
            "/MT:1",                    # Single-threaded para archivos de BD
            "/COPY:DAT",                # Copiar datos, atributos y timestamps
            "/DCOPY:T",                 # Copiar timestamps de directorios
            "/XO",                      # Excluir archivos más antiguos
            "/FFT",                     # Asumir tiempos de archivo FAT
            "/DST",                     # Compensar diferencias de horario de verano
            "/NP",                      # No mostrar progreso
            "/NDL",                     # No mostrar lista de directorios
            "/NJH",                     # No mostrar encabezado de trabajo
            "/NJS"                      # No mostrar resumen de trabajo
        )
        
        $robocopyProcess = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput "robocopy_output.txt" -RedirectStandardError "robocopy_error.txt"
        
        # Robocopy códigos de salida: 0-7 son éxito, 8+ son errores
        if ($robocopyProcess.ExitCode -le 7) {
            # Verificar que la copia fue exitosa
            if (Test-Path $DestinationPath) {
                $destSize = (Get-Item $DestinationPath).Length
                $sourceSize = $sourceFile.Length
                
                if ($sourceSize -eq $destSize) {
                    $elapsed = (Get-Date) - $startTime
                    Write-Log "Base de datos copiada exitosamente con Robocopy en $($elapsed.TotalSeconds)s - Tamaño: $sourceSize bytes" "SUCCESS"
                    
                    # Limpiar archivos temporales
                    Remove-Item "robocopy_output.txt" -ErrorAction SilentlyContinue
                    Remove-Item "robocopy_error.txt" -ErrorAction SilentlyContinue
                    
                    return @{
                        success = $true
                        message = "Base de datos copiada exitosamente con Robocopy de $SourcePath a $DestinationPath"
                        source_size = $sourceSize
                        dest_size = $destSize
                        execution_time = "$($elapsed.TotalSeconds.ToString('F2'))s"
                        method = "PowerShell-Robocopy"
                    }
                } else {
                    throw "Error de integridad: tamaños no coinciden. Origen: $sourceSize, Destino: $destSize"
                }
            } else {
                throw "El archivo destino no fue creado por Robocopy"
            }
        } else {
            # Leer error de Robocopy
            $robocopyError = ""
            if (Test-Path "robocopy_error.txt") {
                $robocopyError = Get-Content "robocopy_error.txt" -Raw
                Remove-Item "robocopy_error.txt" -ErrorAction SilentlyContinue
            }
            Remove-Item "robocopy_output.txt" -ErrorAction SilentlyContinue
            
            throw "Robocopy falló con código $($robocopyProcess.ExitCode): $robocopyError"
        }
    }
    catch {
        $elapsed = (Get-Date) - $startTime
        $errorMsg = $_.Exception.Message
        Write-Log "Copia de base de datos falló después de $($elapsed.TotalSeconds)s: $errorMsg" "ERROR"
        
        # Limpiar archivos temporales en caso de error
        Remove-Item "robocopy_output.txt" -ErrorAction SilentlyContinue
        Remove-Item "robocopy_error.txt" -ErrorAction SilentlyContinue
        
        return @{
            success = $false
            error = $errorMsg
            execution_time = "$($elapsed.TotalSeconds.ToString('F2'))s"
            method = "PowerShell-Robocopy"
        }
    }
}

# Función para ejecutar consulta Firebird
function Execute-FirebirdQuery {
    param(
        [PSCustomObject]$Config,
        [string]$Query,
        [array]$Parameters = @()
    )
    
    $startTime = Get-Date
    
    try {
        Write-Log "Ejecutando consulta Firebird con $($Parameters.Count) parámetros"
        
        $connectionString = Build-FirebirdConnectionString -Config $Config
        $connection = New-Object FirebirdSql.Data.FirebirdClient.FbConnection($connectionString)
        $connection.Open()
        
        $command = New-Object FirebirdSql.Data.FirebirdClient.FbCommand($Query, $connection)
        $command.CommandTimeout = 300  # 5 minutos para consultas largas
        
        # Agregar parámetros
        for ($i = 0; $i -lt $Parameters.Count; $i++) {
            $paramValue = if ($Parameters[$i] -eq $null) { [DBNull]::Value } else { $Parameters[$i] }
            $command.Parameters.AddWithValue("@param$i", $paramValue) | Out-Null
        }
        
        $adapter = New-Object FirebirdSql.Data.FirebirdClient.FbDataAdapter($command)
        $dataset = New-Object System.Data.DataSet
        $rowCount = $adapter.Fill($dataset)
        
        $connection.Close()
        
        # Convertir resultados a formato JSON serializable
        $resultData = @()
        if ($dataset.Tables.Count -gt 0 -and $dataset.Tables[0].Rows.Count -gt 0) {
            foreach ($row in $dataset.Tables[0].Rows) {
                $rowObj = @{}
                foreach ($column in $dataset.Tables[0].Columns) {
                    $value = $row[$column.ColumnName]
                    if ($value -is [DateTime]) {
                        $rowObj[$column.ColumnName] = $value.ToString("yyyy-MM-ddTHH:mm:ss")
                    }
                    elseif ($value -is [DBNull]) {
                        $rowObj[$column.ColumnName] = $null
                    }
                    else {
                        $rowObj[$column.ColumnName] = $value
                    }
                }
                $resultData += $rowObj
            }
        }
        
        $elapsed = (Get-Date) - $startTime
        Write-Log "Consulta Firebird ejecutada exitosamente: $($resultData.Count) filas en $($elapsed.TotalMilliseconds)ms" "SUCCESS"
        
        return @{
            success = $true
            data = $resultData
            rows_count = $resultData.Count
            execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
            method = "PowerShell"
        }
    }
    catch {
        $elapsed = (Get-Date) - $startTime
        $errorMsg = $_.Exception.Message
        Write-Log "Consulta Firebird falló después de $($elapsed.TotalMilliseconds)ms: $errorMsg" "ERROR"
        
        return @{
            success = $false
            error = $errorMsg
            data = @()
            rows_count = 0
            execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
            method = "PowerShell"
        }
    }
}

# Función para ejecutar comando no-query Firebird
function Execute-FirebirdNonQuery {
    param(
        [PSCustomObject]$Config,
        [string]$Query,
        [array]$Parameters = @()
    )
    
    $startTime = Get-Date
    
    try {
        Write-Log "Ejecutando comando Firebird con $($Parameters.Count) parámetros"
        
        $connectionString = Build-FirebirdConnectionString -Config $Config
        $connection = New-Object FirebirdSql.Data.FirebirdClient.FbConnection($connectionString)
        $connection.Open()
        
        $command = New-Object FirebirdSql.Data.FirebirdClient.FbCommand($Query, $connection)
        $command.CommandTimeout = 300  # 5 minutos
        
        # Agregar parámetros
        for ($i = 0; $i -lt $Parameters.Count; $i++) {
            $paramValue = if ($Parameters[$i] -eq $null) { [DBNull]::Value } else { $Parameters[$i] }
            $command.Parameters.AddWithValue("@param$i", $paramValue) | Out-Null
        }
        
        $rowsAffected = $command.ExecuteNonQuery()
        $connection.Close()
        
        $elapsed = (Get-Date) - $startTime
        Write-Log "Comando Firebird ejecutado exitosamente: $rowsAffected filas afectadas en $($elapsed.TotalMilliseconds)ms" "SUCCESS"
        
        return @{
            success = $true
            rows_affected = $rowsAffected
            execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
            method = "PowerShell"
        }
    }
    catch {
        $elapsed = (Get-Date) - $startTime
        $errorMsg = $_.Exception.Message
        Write-Log "Comando Firebird falló después de $($elapsed.TotalMilliseconds)ms: $errorMsg" "ERROR"
        
        return @{
            success = $false
            error = $errorMsg
            rows_affected = 0
            execution_time = "$($elapsed.TotalMilliseconds.ToString('F2'))ms"
            method = "PowerShell"
        }
    }
}

# Función para procesar facturas SAE
function Process-FacturasSAE {
    param(
        [PSCustomObject]$Config,
        [int]$VigenciaDia,
        [int]$DiasFacturas,
        [array]$PalabrasExcluidas,
        [array]$PalabrasConvenio,
        [array]$PalabrasCicloEscolar,
        [int]$VigenciaConvenio,
        [int]$VigenciaCicloEscolar
    )
    
    $startTime = Get-Date
    
    try {
        Write-Log "Iniciando procesamiento de facturas SAE - Días: $DiasFacturas, Día vigencia: $VigenciaDia"
        
        # Validar tablas requeridas
        $validationResult = Test-RequiredTables -Config $Config
        if (-not $validationResult.success) {
            return $validationResult
        }
        
        # Consulta de facturas optimizada
        $facturasSql = @"
            SELECT FIRST 2000 
                f.CVE_DOC, 
                f.FECHA_DOC, 
                f.CVE_CLPV, 
                COALESCE(f.OBSERVS, '') as OBSERVS, 
                f.STATUS,
                COALESCE(c.NOMBRE, '') as NOMBRE, 
                c.CVE_CLPV as CLIENTE_ID,
                COALESCE(c.VIGENCIA, CURRENT_DATE) as VIGENCIA_ACTUAL
            FROM FACTURAS f
            LEFT JOIN CLPV c ON f.CVE_CLPV = c.CVE_CLPV
            WHERE f.FECHA_DOC >= (CURRENT_DATE - ?)
                AND COALESCE(f.STATUS, '') = 'E'
                AND f.CVE_CLPV IS NOT NULL
                AND TRIM(COALESCE(f.CVE_CLPV, '')) <> ''
            ORDER BY f.FECHA_DOC DESC, f.CVE_DOC DESC
"@
        
        # Ejecutar consulta de facturas
        $queryResult = Execute-FirebirdQuery -Config $Config -Query $facturasSql -Parameters @($DiasFacturas)
        if (-not $queryResult.success) {
            return @{
                success = $false
                message = "Error consultando facturas: $($queryResult.error)"
                facturas_processed = 0
                vigencias_updated = 0
                errors = @($queryResult.error)
                method = "PowerShell"
            }
        }
        
        $facturas = $queryResult.data
        Write-Log "Encontradas $($facturas.Count) facturas para procesar"
        
        # Procesar facturas
        $updates = @()
        $facturasProcessed = 0
        $facturasExcluidas = 0
        $tiposVigencia = @{normal = 0; convenio = 0; ciclo_escolar = 0}
        
        foreach ($factura in $facturas) {
            try {
                $observaciones = $factura.OBSERVS.ToString().ToUpper().Trim()
                $clienteId = $factura.CLIENTE_ID.ToString().Trim()
                $fechaFactura = [DateTime]::Parse($factura.FECHA_DOC)
                $cveDoc = $factura.CVE_DOC
                
                if ([string]::IsNullOrEmpty($clienteId)) {
                    continue
                }
                
                # Verificar palabras excluidas
                $tieneExcluidas = $false
                foreach ($palabra in $PalabrasExcluidas) {
                    if (-not [string]::IsNullOrEmpty($palabra) -and $observaciones.Contains($palabra.ToUpper().Trim())) {
                        $tieneExcluidas = $true
                        break
                    }
                }
                
                if ($tieneExcluidas) {
                    $facturasExcluidas++
                    continue
                }
                
                # Determinar tipo de vigencia
                $tieneCicloEscolar = $false
                foreach ($palabra in $PalabrasCicloEscolar) {
                    if (-not [string]::IsNullOrEmpty($palabra) -and $observaciones.Contains($palabra.ToUpper().Trim())) {
                        $tieneCicloEscolar = $true
                        break
                    }
                }
                
                $tieneConvenio = $false
                if (-not $tieneCicloEscolar) {
                    foreach ($palabra in $PalabrasConvenio) {
                        if (-not [string]::IsNullOrEmpty($palabra) -and $observaciones.Contains($palabra.ToUpper().Trim())) {
                            $tieneConvenio = $true
                            break
                        }
                    }
                }
                
                # Calcular nueva vigencia
                if ($tieneCicloEscolar) {
                    $nuevaVigencia = $fechaFactura.AddDays($VigenciaCicloEscolar)
                    $tipoVigencia = "ciclo_escolar"
                } elseif ($tieneConvenio) {
                    $nuevaVigencia = $fechaFactura.AddDays($VigenciaConvenio)
                    $tipoVigencia = "convenio"
                } else {
                    $nuevaVigencia = Get-NextVigenciaDate -VigenciaDia $VigenciaDia
                    $tipoVigencia = "normal"
                }
                
                $updates += @{
                    ClienteId = $clienteId
                    NuevaVigencia = $nuevaVigencia
                    TipoVigencia = $tipoVigencia
                    Observaciones = $observaciones
                }
                
                $tiposVigencia[$tipoVigencia]++
                $facturasProcessed++
                
                if ($facturasProcessed % 100 -eq 0) {
                    Write-Log "Procesadas $facturasProcessed facturas hasta ahora..."
                }
            }
            catch {
                Write-Log "Error procesando factura $($factura.CVE_DOC): $($_.Exception.Message)" "WARN"
                continue
            }
        }
        
        Write-Log "Consulta completada. Procesando $($updates.Count) actualizaciones..."
        
        # Actualizar vigencias en lotes
        $vigenciasUpdated = 0
        $batchSize = 50
        $errors = @()
        
        for ($i = 0; $i -lt $updates.Count; $i += $batchSize) {
            $batch = $updates[$i..([Math]::Min($i + $batchSize - 1, $updates.Count - 1))]
            
            try {
                $connectionString = Build-FirebirdConnectionString -Config $Config
                $connection = New-Object FirebirdSql.Data.FirebirdClient.FbConnection($connectionString)
                $connection.Open()
                
                foreach ($update in $batch) {
                    $updateSql = "UPDATE CLPV SET VIGENCIA = ? WHERE CVE_CLPV = ? AND (VIGENCIA IS NULL OR VIGENCIA < ?)"
                    $command = New-Object FirebirdSql.Data.FirebirdClient.FbCommand($updateSql, $connection)
                    $command.CommandTimeout = 300
                    $command.Parameters.AddWithValue("@vigencia", $update.NuevaVigencia) | Out-Null
                    $command.Parameters.AddWithValue("@cliente", $update.ClienteId) | Out-Null
                    $command.Parameters.AddWithValue("@vigencia_check", $update.NuevaVigencia) | Out-Null
                    
                    $rowsAffected = $command.ExecuteNonQuery()
                    if ($rowsAffected -gt 0) {
                        $vigenciasUpdated++
                    }
                }
                
                $connection.Close()
                
                if (($i / $batchSize + 1) % 10 -eq 0) {
                    Write-Log "Completado lote $([Math]::Floor($i / $batchSize) + 1)/$([Math]::Ceiling($updates.Count / $batchSize))"
                }
            }
            catch {
                $errorMsg = "Error actualizando lote iniciando en índice $i`: $($_.Exception.Message)"
                $errors += $errorMsg
                Write-Log $errorMsg "ERROR"
            }
        }
        
        $elapsed = (Get-Date) - $startTime
        
        $resultMessage = "Procesamiento completado en $($elapsed.TotalSeconds.ToString('F1'))s. " +
                        "$facturasProcessed facturas procesadas ($facturasExcluidas excluidas), " +
                        "$vigenciasUpdated vigencias actualizadas. " +
                        "Tipos: $($tiposVigencia.normal) normales, $($tiposVigencia.convenio) convenios, " +
                        "$($tiposVigencia.ciclo_escolar) ciclos escolares."
        
        Write-Log "Procesamiento de facturas SAE completado exitosamente: $resultMessage" "SUCCESS"
        
        return @{
            success = $true
            message = $resultMessage
            facturas_processed = $facturasProcessed
            vigencias_updated = $vigenciasUpdated
            errors = $errors
            execution_time = "$($elapsed.TotalSeconds.ToString('F2'))s"
            statistics = @{
                facturas_excluidas = $facturasExcluidas
                vigencias_normales = $tiposVigencia.normal
                vigencias_convenio = $tiposVigencia.convenio
                vigencias_ciclo_escolar = $tiposVigencia.ciclo_escolar
                total_updates_attempted = $updates.Count
            }
            method = "PowerShell"
        }
    }
    catch {
        $elapsed = (Get-Date) - $startTime
        $errorMsg = "Error durante procesamiento de facturas SAE: $($_.Exception.Message)"
        Write-Log "$errorMsg (después de $($elapsed.TotalSeconds.ToString('F2'))s)" "ERROR"
        
        return @{
            success = $false
            message = $errorMsg
            facturas_processed = 0
            vigencias_updated = 0
            errors = @($errorMsg)
            execution_time = "$($elapsed.TotalSeconds.ToString('F2'))s"
            method = "PowerShell"
        }
    }
}

# Función para validar tablas requeridas
function Test-RequiredTables {
    param([PSCustomObject]$Config)
    
    try {
        $tables = @("FACTURAS", "CLPV")
        foreach ($table in $tables) {
            $checkSql = "SELECT COUNT(*) FROM RDB`$RELATIONS WHERE RDB`$RELATION_NAME = ? AND RDB`$RELATION_TYPE = 0"
            
            $result = Execute-FirebirdQuery -Config $Config -Query $checkSql -Parameters @($table)
            if (-not $result.success) {
                return @{
                    success = $false
                    error = "Error verificando tabla $table`: $($result.error)"
                }
            }
            
            $count = 0
            if ($result.data.Count -gt 0) {
                $row = $result.data[0]
                foreach ($key in $row.Keys) {
                    if ($key.ToUpper().Contains('COUNT')) {
                        $count = $row[$key]
                        break
                    }
                }
            }
            
            if ($count -eq 0) {
                return @{
                    success = $false
                    error = "Tabla requerida '$table' no encontrada en la base de datos"
                }
            }
        }
        
        Write-Log "Todas las tablas requeridas validadas exitosamente" "SUCCESS"
        return @{ success = $true }
    }
    catch {
        return @{
            success = $false
            error = "Error validando tablas: $($_.Exception.Message)"
        }
    }
}

# Función para calcular próxima fecha de vigencia
function Get-NextVigenciaDate {
    param([int]$VigenciaDia)
    
    $hoy = Get-Date
    $año = $hoy.Year
    $mes = $hoy.Month
    
    # Obtener días en el mes actual
    $diasEnMes = [DateTime]::DaysInMonth($año, $mes)
    $diaVigencia = [Math]::Min($VigenciaDia, $diasEnMes)
    $proximaVigencia = Get-Date -Year $año -Month $mes -Day $diaVigencia -Hour 0 -Minute 0 -Second 0
    
    if ($proximaVigencia -le $hoy) {
        if ($mes -eq 12) {
            $año++
            $mes = 1
        } else {
            $mes++
        }
        
        $diasEnMes = [DateTime]::DaysInMonth($año, $mes)
        $diaVigencia = [Math]::Min($VigenciaDia, $diasEnMes)
        $proximaVigencia = Get-Date -Year $año -Month $mes -Day $diaVigencia -Hour 0 -Minute 0 -Second 0
    }
    
    return $proximaVigencia
}

# Función principal
function Main {
    try {
        Write-Log "Iniciando FirebirdBridge PowerShell - Operación: $Operation"
        
        # Cargar ensamblados .NET
        if (-not (Load-RequiredAssemblies)) {
            throw "No se pudieron cargar los ensamblados .NET necesarios. Ejecute install_libs.bat primero."
        }
        
        # Parsear configuración JSON
        $config = $null
        if ($ConfigJson -ne "{}") {
            try {
                $config = $ConfigJson | ConvertFrom-Json
            } catch {
                throw "Error parseando configuración JSON: $($_.Exception.Message)"
            }
        }
        
        # Ejecutar operación solicitada
        $result = switch ($Operation.ToLower()) {
            "test_connection" {
                if (-not $config) { throw "Configuración requerida para test_connection" }
                Test-FirebirdConnection -Config $config
            }
            "test_mysql_connection" {
                if (-not $config) { throw "Configuración requerida para test_mysql_connection" }
                Test-MySQLConnection -Config $config
            }
            "execute_query" {
                if (-not $config -or -not $Query) { throw "Configuración y consulta requeridas para execute_query" }
                $params = if ($Parameters -ne "[]") { $Parameters | ConvertFrom-Json } else { @() }
                Execute-FirebirdQuery -Config $config -Query $Query -Parameters $params
            }
            "execute_non_query" {
                if (-not $config -or -not $Query) { throw "Configuración y consulta requeridas para execute_non_query" }
                $params = if ($Parameters -ne "[]") { $Parameters | ConvertFrom-Json } else { @() }
                Execute-FirebirdNonQuery -Config $config -Query $Query -Parameters $params
            }
            "copy_database" {
                if (-not $SourcePath -or -not $DestinationPath) { throw "Rutas origen y destino requeridas para copy_database" }
                Copy-Database -SourcePath $SourcePath -DestinationPath $DestinationPath
            }
            "process_facturas" {
                if (-not $config) { throw "Configuración requerida para process_facturas" }
                $palabrasExc = if ($PalabrasExcluidas -ne "[]") { $PalabrasExcluidas | ConvertFrom-Json } else { @() }
                $palabrasConv = if ($PalabrasConvenio -ne "[]") { $PalabrasConvenio | ConvertFrom-Json } else { @() }
                $palabrasCiclo = if ($PalabrasCicloEscolar -ne "[]") { $PalabrasCicloEscolar | ConvertFrom-Json } else { @() }
                Process-FacturasSAE -Config $config -VigenciaDia $VigenciaDia -DiasFacturas $DiasFacturas -PalabrasExcluidas $palabrasExc -PalabrasConvenio $palabrasConv -PalabrasCicloEscolar $palabrasCiclo -VigenciaConvenio $VigenciaConvenio -VigenciaCicloEscolar $VigenciaCicloEscolar
            }
            default {
                @{
                    success = $false
                    error = "Operación desconocida: $Operation"
                    method = "PowerShell"
                }
            }
        }
        
        # Convertir resultado a JSON y escribir a salida
        $jsonResult = $result | ConvertTo-Json -Depth 10 -Compress
        Write-Output $jsonResult
        
        Write-Log "Operación $Operation completada exitosamente"
    }
    catch {
        $errorResult = @{
            success = $false
            error = $_.Exception.Message
            operation = $Operation
            method = "PowerShell"
            stack_trace = $_.ScriptStackTrace
        }
        
        $jsonError = $errorResult | ConvertTo-Json -Depth 10 -Compress
        Write-Output $jsonError
        
        Write-Log "Error en operación $Operation`: $($_.Exception.Message)" "ERROR"
        exit 1
    }
}

# Ejecutar función principal
Main