# Conectar ao Azure
Connect-AzAccount

# Parâmetros necessários
$subscriptionId = "76f7ed29-398d-42db-b453-5a855b69bf2e"
$arcServersResourceGroup = "RG-lab-sentinel-2" # RG das máquinas do ARC

# Definição de múltiplas DCRs
$dcrs = @(
    @{
        Name = "DCR_LINUX"
        ResourceGroupName = "RG-lab-sentinel-2"
    },
    @{
        Name = "DCR_Windows"
        ResourceGroupName = "RG-lab-sentinel-2"
    }
)

$machinesFilePath = "./lista_maquinas.txt"
if (-Not (Test-Path $machinesFilePath)) {
    Write-Error "Arquivo de máquinas não encontrado!"
    exit
}

# Ler a lista de máquinas e remover linhas vazias
$targetMachines = Get-Content -Path $machinesFilePath | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

if ($targetMachines.Count -eq 0) {
    Write-Error "O arquivo não contém nenhuma máquina válida!"
    exit
}

# Selecionar a subscription
Set-AzContext -SubscriptionId $subscriptionId

# Função para selecionar DCR
function Select-DCR {
    param (
        [string]$actionType
    )
    
   Write-Host "`nSelecione a DCR para ${actionType}:"
    
    for ($i = 0; $i -lt $dcrs.Count; $i++) {
        $dcr = $dcrs[$i]
        # Obter detalhes da DCR para mostrar o tipo (Windows/Linux)
        try {
            $dcrInfo = Get-AzDataCollectionRule -ResourceGroupName $dcr.ResourceGroupName -Name $dcr.Name
            $dcrType = $dcrInfo.Kind
            Write-Host "$($i+1) - $($dcr.Name) (Tipo: $dcrType) no grupo de recursos $($dcr.ResourceGroupName)"
        }
        catch {
            Write-Host "$($i+1) - $($dcr.Name) no grupo de recursos $($dcr.ResourceGroupName) [Erro ao obter tipo]"
        }
    }
    
    $dcrOption = Read-Host "Digite o número da DCR"
    
    if ($dcrOption -match '^\d+$' -and [int]$dcrOption -ge 1 -and [int]$dcrOption -le $dcrs.Count) {
        return $dcrs[[int]$dcrOption - 1]
    }
    else {
        Write-Error "Opção de DCR inválida!"
        exit
    }
}

# Função para exibir o resultado
function Show-Result {
    param (
        [string]$header,
        [array]$machines,
        [string]$motivo
    )

    Write-Host "`n### $header ###"
    if ($machines.Count -gt 0) {
        if ($motivo) { Write-Host "Motivo: $motivo" }
        $machines | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina encontrada."
    }
}

# Adicionar nova função de resumo executivo
function Show-ExecutiveSummary {
    param (
        [string]$operationType,
        [array]$targetMachines,
        [array]$successMachines,
        [hashtable]$failedMachines,
        [string]$dcrName
    )

    $totalMachines = $targetMachines.Count
    
    Write-Host "`n`n========== RESUMO EXECUTIVO ==========`n"
    Write-Host "Arquivo de referência possui $totalMachines ativos listados."
    
    switch ($operationType) {
        "DCR-Add" {
            $addedToDCR = $successMachines.Count
            $alreadyInDCR = $failedMachines.JaAssociada.Count
            $incompatibleOS = $failedMachines.SOIncompativel.Count
            $notInArc = $failedMachines.NaoExisteNoArc.Count
            $errors = $failedMachines.ErroAoAdicionar.Count + $failedMachines.ErroAoProcessar.Count

            Write-Host "`nResultados da adição à DCR '$dcrName':"
            Write-Host "- $addedToDCR máquinas foram adicionadas com sucesso"
            Write-Host "- $alreadyInDCR máquinas já estavam associadas"
            Write-Host "- $incompatibleOS máquinas possuem Sistema Operacional incompatível"
            Write-Host "- $notInArc máquinas não existem no Azure Arc"
            Write-Host "- $errors máquinas apresentaram erros durante o processo"
        }
        "DCR-Remove" {
            $removedFromDCR = $successMachines.Count
            $notInDCR = $failedMachines.NaoAssociadaADCR.Count
            $differentDCR = $failedMachines.AssociacaoDiferente.Count
            $notInArc = $failedMachines.NaoExisteNoArc.Count
            $errors = $failedMachines.ErroAoRemover.Count + $failedMachines.ErroAoProcessar.Count

            Write-Host "`nResultados da remoção da DCR '$dcrName':"
            Write-Host "- $removedFromDCR máquinas foram removidas com sucesso"
            Write-Host "- $notInDCR máquinas não estavam associadas à DCR"
            Write-Host "- $differentDCR máquinas estão associadas a outras DCRs"
            Write-Host "- $notInArc máquinas não existem no Azure Arc"
            Write-Host "- $errors máquinas apresentaram erros durante o processo"
        }
        "ARC-Remove" {
            $removedFromArc = $successMachines.Count
            $notInArc = $failedMachines.NaoExisteNoArc.Count
            $errors = $failedMachines.ErroAoRemover.Count + $failedMachines.ErroAoProcessar.Count

            Write-Host "`nResultados da remoção do Azure Arc:"
            Write-Host "- $removedFromArc máquinas tiveram o agente removido com sucesso"
            Write-Host "- $notInArc máquinas não existem no Azure Arc"
            Write-Host "- $errors máquinas apresentaram erros durante o processo"
        }
    }

    # Calcular percentual de sucesso
    $successPercentage = 0
    if ($totalMachines -gt 0) {
        $successPercentage = [math]::Round(($successMachines.Count / $totalMachines) * 100, 2)
    }

    Write-Host "`nTaxa de sucesso da operação: $successPercentage%"
    Write-Host "`n====================================`n"
}

# Função para adicionar máquinas à DCR
function Add-MachinesToDCR {
    # Selecionar a DCR
    $selectedDcr = Select-DCR -actionType "adicionar máquinas"
    $resourceGroupName = $selectedDcr.ResourceGroupName
    $dcrName = $selectedDcr.Name

    # Obter todas as máquinas Arc existentes
    $arcMachines = Get-AzConnectedMachine -ResourceGroupName $arcServersResourceGroup

# Identificar máquinas que não existem no Arc - com tratamento de nomes especiais
$nonExistentMachines = $targetMachines | Where-Object {
    $machineName = $_
    -not ($arcMachines | Where-Object { $_.Name -eq $machineName -or $_.DisplayName -eq $machineName })
}

$arcMachines = $arcMachines | Where-Object { 
    $machine = $_
    $targetMachines | Where-Object { $_ -eq $machine.Name -or $_ -eq $machine.DisplayName }
}

    # Obter a DCR específica
    try {
        $targetDcr = Get-AzDataCollectionRule -ResourceGroupName $resourceGroupName -Name $dcrName
        Write-Host "DCR alvo: $dcrName"
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Error "Erro ao obter a DCR ${dcrName}: $errorMessage"
        exit
    }

    $successMachines = @()
    $failedMachines = @{
        "JaAssociada" = @()
        "SOIncompativel" = @()
        "ErroAoAdicionar" = @()
        "ErroAoProcessar" = @()
        "NaoExisteNoArc" = $nonExistentMachines
    }

    $jobs = @()

    foreach ($machine in $arcMachines) {
        $machineDetails = Get-AzConnectedMachine -ResourceGroupName $arcServersResourceGroup -Name $machine.Name
        $machineResourceId = $machineDetails.Id
        $machineOsType = $machineDetails.OSName
        $machineLocation = $machineDetails.Location

        Write-Host "Processando máquina $($machine.Name)"

        try {
            # Verificar compatibilidade do sistema operacional
            $isCompatible = $false
            if ($targetDcr.Kind -eq "Windows" -and $machineOsType -like "*Windows*") {
                $isCompatible = $true
            }
            elseif ($targetDcr.Kind -eq "Linux" -and $machineOsType -like "*Linux*") {
                $isCompatible = $true
            }

            if (-not $isCompatible) {
                Write-Warning "Sistema operacional incompatível para máquina $($machine.Name): $machineOsType"
                $failedMachines.SOIncompativel += "Máquina: $($machine.Name) - SO: $machineOsType"
                continue
            }

            # Verificar se já existe associação
            $existingAssociations = Get-AzDataCollectionRuleAssociation -TargetResourceId $machineResourceId
            $alreadyAssociated = $false

            foreach ($association in $existingAssociations) {
                if ($association.DataCollectionRuleId -eq $targetDcr.Id) {
                    $alreadyAssociated = $true
                    break
                }
            }

            if ($alreadyAssociated) {
                Write-Host "Máquina $($machine.Name) já está associada à DCR $dcrName"
                $failedMachines.JaAssociada += "Máquina: $($machine.Name)"
                continue
            }

            # Remover extensão antiga do AMA se existir
            try {
                $existingExtensions = Get-AzConnectedMachineExtension -ResourceGroupName $arcServersResourceGroup -MachineName $machine.Name
                foreach ($extension in $existingExtensions) {
                    if ($extension.Publisher -eq "Microsoft.Azure.Monitor" -and ($extension.Type -eq "AzureMonitorLinuxAgent" -or $extension.Type -eq "AzureMonitorWindowsAgent")) {
                        Remove-AzConnectedMachineExtension -ResourceGroupName $arcServersResourceGroup -MachineName $machine.Name -Name $extension.Name -Force
                        Write-Host "Extensão antiga do AMA removida para máquina $($machine.Name)"
                    }
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Erro ao remover extensão antiga do AMA para máquina $($machine.Name): $errorMessage"
                $failedMachines.ErroAoProcessar += "Máquina: $($machine.Name) - Erro: $errorMessage"
                continue
            }

            # Instalar nova extensão do AMA em segundo plano
            try {
                $extensionName = $null
                $publisher = "Microsoft.Azure.Monitor"
                $type = $null

                if ($machineOsType -like "*Windows*") {
                    $extensionName = "AzureMonitorWindowsAgent"
                    $type = "AzureMonitorWindowsAgent"
                }
                elseif ($machineOsType -like "*Linux*") {
                    $extensionName = "AzureMonitorLinuxAgent"
                    $type = "AzureMonitorLinuxAgent"
                }

                if ($extensionName -and $type) {
                    $job = Start-Job -ScriptBlock {
                        param ($extensionName, $type, $publisher, $arcServersResourceGroup, $machine, $machineLocation)
                        New-AzConnectedMachineExtension -Name $extensionName -ExtensionType $type -Publisher $publisher -ResourceGroupName $arcServersResourceGroup -MachineName $machine.Name -Location $machineLocation
                    } -ArgumentList $extensionName, $type, $publisher, $arcServersResourceGroup, $machine, $machineLocation
                    $jobs += [PSCustomObject]@{ MachineName = $machine.Name; Job = $job }
                    Write-Host "Instalação da extensão do AMA iniciada em segundo plano para máquina $($machine.Name)"
                }
                else {
                    Write-Warning "Tipo de extensão não reconhecido para máquina $($machine.Name)"
                    $failedMachines.ErroAoProcessar += "Máquina: $($machine.Name) - Tipo de extensão não reconhecido"
                    continue
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Erro ao instalar extensão do AMA para máquina $($machine.Name): $errorMessage"
                $failedMachines.ErroAoProcessar += "Máquina: $($machine.Name) - Erro: $errorMessage"
                continue
            }

            # Criar nova associação
            try {
                $associationName = "$($machine.Name)_DCR_Association"
                New-AzDataCollectionRuleAssociation -TargetResourceId $machineResourceId -AssociationName $associationName -RuleId $targetDcr.Id
                Write-Host "Associação criada com sucesso para máquina $($machine.Name)"
                $successMachines += "Máquina: $($machine.Name)"
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Warning "Erro ao criar associação para máquina $($machine.Name): $errorMessage"
                $failedMachines.ErroAoAdicionar += "Máquina: $($machine.Name) - Erro: $errorMessage"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Error "Erro ao processar máquina $($machine.Name): $errorMessage"
            $failedMachines.ErroAoProcessar += "Máquina: $($machine.Name) - Erro: $errorMessage"
        }
    }

    # Relatório de Sucesso
    Write-Host "`n### Máquinas adicionadas com sucesso à DCR $dcrName ###"
    if ($successMachines.Count -gt 0) {
        $successMachines | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina adicionada com sucesso."
    }

    # Relatório de Falhas por Categoria
    Write-Host "`n### Relatório de Falhas ###"
    
    Write-Host "`nMáquinas não encontradas no Azure Arc:"
    if ($failedMachines.NaoExisteNoArc.Count -gt 0) {
        $failedMachines.NaoExisteNoArc | ForEach-Object { Write-Host "Máquina: $_" }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas já associadas à DCR:"
    if ($failedMachines.JaAssociada.Count -gt 0) {
        $failedMachines.JaAssociada | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com SO incompatível:"
    if ($failedMachines.SOIncompativel.Count -gt 0) {
        $failedMachines.SOIncompativel | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com erro na adição:"
    if ($failedMachines.ErroAoAdicionar.Count -gt 0) {
        $failedMachines.ErroAoAdicionar | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com erro no processamento:"
    if ($failedMachines.ErroAoProcessar.Count -gt 0) {
        $failedMachines.ErroAoProcessar | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    # Exibir resumo executivo
    Show-ExecutiveSummary -operationType "DCR-Add" `
                         -targetMachines $targetMachines `
                         -successMachines $successMachines `
                         -failedMachines $failedMachines `
                         -dcrName $dcrName
}

# Função para remover máquinas da DCR
function Remove-MachinesFromDCR {
    # Selecionar a DCR
    $selectedDcr = Select-DCR -actionType "remover máquinas"
    $resourceGroupName = $selectedDcr.ResourceGroupName
    $dcrName = $selectedDcr.Name
    
    # Obter todas as máquinas Arc existentes
    $arcMachines = Get-AzConnectedMachine -ResourceGroupName $arcServersResourceGroup
    
# Identificar máquinas que não existem no Arc - com tratamento de nomes especiais
$nonExistentMachines = $targetMachines | Where-Object {
    $machineName = $_
    -not ($arcMachines | Where-Object { $_.Name -eq $machineName -or $_.DisplayName -eq $machineName })
}

$arcMachines = $arcMachines | Where-Object { 
    $machine = $_
    $targetMachines | Where-Object { $_ -eq $machine.Name -or $_ -eq $machine.DisplayName }
}

    # Obter a DCR específica
    try {
        $targetDcr = Get-AzDataCollectionRule -ResourceGroupName $resourceGroupName -Name $dcrName
        Write-Host "DCR alvo: $dcrName"
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Error "Erro ao obter a DCR ${dcrName}: $errorMessage"
        exit
    }

    $successMachines = @()
    $failedMachines = @{
        "NaoAssociadaADCR" = @()
        "AssociacaoDiferente" = @()
        "ErroAoRemover" = @()
        "ErroAoProcessar" = @()
        "NaoExisteNoArc" = $nonExistentMachines
    }

    foreach ($machine in $arcMachines) {
        $machineDetails = Get-AzConnectedMachine -ResourceGroupName $arcServersResourceGroup -Name $machine.Name
        $machineResourceId = $machineDetails.Id

        Write-Host "Processando máquina $($machine.Name)"

        try {
            # Obtém todas as associações
            $associations = Get-AzDataCollectionRuleAssociation -TargetResourceId $machineResourceId
            
            if ($associations) {
                $dcrFound = $false
                foreach ($association in $associations) {
                    # Verifica se a associação é com a DCR específica
                    if ($association.DataCollectionRuleId -eq $targetDcr.Id) {
                        $dcrFound = $true
                        try {
                            # Remove a associação
                            Remove-AzDataCollectionRuleAssociation -TargetResourceId $machineResourceId -AssociationName $association.Name -ErrorAction Stop
                            Write-Host "Associação com DCR $dcrName removida com sucesso da máquina $($machine.Name)"
                            $successMachines += "Máquina: $($machine.Name)"
                        }
                        catch {
                            $errorMessage = $_.Exception.Message
                            Write-Warning "Erro ao remover associação da máquina $($machine.Name): $errorMessage"
							$failedMachines.ErroAoRemover += "Máquina: $($machine.Name) - Erro: $errorMessage"
                        }
                    }
                }
                
                if (-not $dcrFound) {
                    Write-Host "Máquina $($machine.Name) possui associações, mas não com a DCR $dcrName"
                    $failedMachines.AssociacaoDiferente += "Máquina: $($machine.Name) - Possui outras associações DCR"
                }
            }
            else {
                Write-Host "Máquina $($machine.Name) não possui associações DCR"
                $failedMachines.NaoAssociadaADCR += "Máquina: $($machine.Name)"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Error "Erro ao processar máquina $($machine.Name): $errorMessage"
            $failedMachines.ErroAoProcessar += "Máquina: $($machine.Name) - Erro: $errorMessage"
        }
    }

    # Relatório de Sucesso
    Write-Host "`n### Máquinas removidas com sucesso da DCR $dcrName ###"
    if ($successMachines.Count -gt 0) {
        $successMachines | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina removida com sucesso."
    }

    # Relatório de Falhas por Categoria
    Write-Host "`n### Relatório de Falhas ###"
    
    Write-Host "`nMáquinas não encontradas no Azure Arc:"
    if ($failedMachines.NaoExisteNoArc.Count -gt 0) {
        $failedMachines.NaoExisteNoArc | ForEach-Object { Write-Host "Máquina: $_" }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas sem associação com DCR:"
    if ($failedMachines.NaoAssociadaADCR.Count -gt 0) {
        $failedMachines.NaoAssociadaADCR | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com outras associações DCR:"
    if ($failedMachines.AssociacaoDiferente.Count -gt 0) {
        $failedMachines.AssociacaoDiferente | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com erro na remoção:"
    if ($failedMachines.ErroAoRemover.Count -gt 0) {
        $failedMachines.ErroAoRemover | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com erro no processamento:"
    if ($failedMachines.ErroAoProcessar.Count -gt 0) {
        $failedMachines.ErroAoProcessar | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }
	
    Show-ExecutiveSummary -operationType "DCR-Remove" `
                         -targetMachines $targetMachines `
                         -successMachines $successMachines `
                         -failedMachines $failedMachines `
                         -dcrName $dcrName
}

# Função para remover agentes do ARC
function Remove-AgentsFromARC {
    # Obter todas as máquinas Arc em todas as subscrições
    $allArcMachines = Get-AzConnectedMachine
    
# Identificar máquinas que não existem no Arc - com tratamento de nomes especiais
$nonExistentMachines = $targetMachines | Where-Object {
    $machineName = $_
    -not ($arcMachines | Where-Object { $_.Name -eq $machineName -or $_.DisplayName -eq $machineName })
}

    $allArcMachines = $allArcMachines | Where-Object { $targetMachines -contains $_.Name }

    $successMachines = @()
    $failedMachines = @{
        "ErroAoRemover" = @()
        "ErroAoProcessar" = @()
        "NaoExisteNoArc" = $nonExistentMachines
    }

    foreach ($machine in $allArcMachines) {
        Write-Host "Processando remoção do agente da máquina $($machine.Name) do grupo de recurso $($machine.ResourceGroupName)"

        try {
            # Remover a máquina do Arc usando o cmdlet correto
            Remove-AzConnectedMachine -ResourceGroupName $machine.ResourceGroupName -Name $machine.Name -ErrorAction Stop
            Write-Host "Agente do Azure Arc removido com sucesso da máquina $($machine.Name)"
            $successMachines += "Máquina: $($machine.Name) do grupo $($machine.ResourceGroupName)"
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warning "Erro ao remover agente da máquina $($machine.Name): $errorMessage"
            $failedMachines.ErroAoRemover += "Máquina: $($machine.Name) do grupo $($machine.ResourceGroupName) - Erro: $errorMessage"
        }
    }

    # Relatório de Sucesso
    Write-Host "`n### Máquinas com agente removido com sucesso ###"
    if ($successMachines.Count -gt 0) {
        $successMachines | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina teve o agente removido com sucesso."
    }

    # Relatório de Falhas
    Write-Host "`n### Relatório de Falhas ###"
    
    Write-Host "`nMáquinas não encontradas no Azure Arc:"
    if ($failedMachines.NaoExisteNoArc.Count -gt 0) {
        $failedMachines.NaoExisteNoArc | ForEach-Object { Write-Host "Máquina: $_" }
    } else {
        Write-Host "Nenhuma máquina nesta categoria."
    }

    Write-Host "`nMáquinas com erro na remoção do agente:"
    if ($failedMachines.ErroAoRemover.Count -gt 0) {
        $failedMachines.ErroAoRemover | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina com erro nesta categoria."
    }

    Write-Host "`nMáquinas com erro no processamento:"
    if ($failedMachines.ErroAoProcessar.Count -gt 0) {
        $failedMachines.ErroAoProcessar | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Nenhuma máquina com erro no processamento."
    }
	
    Show-ExecutiveSummary -operationType "ARC-Remove" `
                         -targetMachines $targetMachines `
                         -successMachines $successMachines `
                         -failedMachines $failedMachines
}

# Função para adicionar nova DCR
function Add-NewDCR {
    Write-Host "`nAdicionar nova DCR ao script"
    $newDcrName = Read-Host "Digite o nome da nova DCR"
    $newDcrRG = Read-Host "Digite o nome do Grupo de Recursos da nova DCR"
    
    # Verificar se a DCR existe
    try {
        $dcrInfo = Get-AzDataCollectionRule -ResourceGroupName $newDcrRG -Name $newDcrName
        $dcrs += @{ Name = $newDcrName; ResourceGroupName = $newDcrRG }
        Write-Host "DCR $newDcrName adicionada com sucesso!"
    }
    catch {
        Write-Error "Erro ao adicionar DCR. Verifique se o nome e o grupo de recursos estão corretos."
    }
}

# Nova função para obter todas as máquinas (Arc e Virtual)
function Get-AllMachines {
    $arcMachines = Get-AzConnectedMachine -ResourceGroupName $arcServersResourceGroup
    $virtualMachines = Get-AzVM -ResourceGroupName $arcServersResourceGroup

    $allMachines = @()
    $allMachines += $arcMachines
    $allMachines += $virtualMachines

    return $allMachines | Where-Object { 
        $machine = $_
        $targetMachines | Where-Object { $_ -eq $machine.Name -or $_ -eq $machine.DisplayName }
    }
}


# Nova função para remover extensão AMA
function Remove-AMAExtension {
    param (
        [string]$osType
    )

    $allMachines = Get-AllMachines

    $successMachines = @()
    $failedMachines = @()

    foreach ($machine in $allMachines) {
        $resourceGroup = $machine.ResourceGroupName
        $machineName = $machine.Name

        $extensionName = if ($osType -eq "Windows") { "AzureMonitorWindowsAgent" } else { "AzureMonitorLinuxAgent" }

        try {
            # Para máquinas virtuais
            if ($machine.Type -eq "Microsoft.Compute/virtualMachines") {
                Remove-AzVMExtension -ResourceGroupName $resourceGroup -VMName $machineName -Name $extensionName -Force
            }
            # Para máquinas Arc
            elseif ($machine.Type -like "*HybridCompute/machines") {
                Remove-AzConnectedMachineExtension -ResourceGroupName $resourceGroup -MachineName $machineName -Name $extensionName -Force
            }

            $successMachines += $machineName
            Write-Host "Extensão $extensionName removida com sucesso da máquina $machineName"
        }
        catch {
            $errorMessage = $_.Exception.Message
            $failedMachines += $machineName
            Write-Warning ("Erro ao remover extensão da máquina {0}: {1}" -f $machineName, $errorMessage)
        }
    }

    Write-Host "`nResumo da remoção de extensão ${osType}:"
    Write-Host "Máquinas com sucesso: $($successMachines.Count)"
    Write-Host "Máquinas com falha: $($failedMachines.Count)"

    if ($failedMachines.Count -gt 0) {
        Write-Host "`nMáquinas com falha:"
        $failedMachines | ForEach-Object { Write-Host $_ }
    }
}

# Nova função para listar DCRs de máquinas
function Get-MachineDCRs {
    $subscriptionId = "76f7ed29-398d-42db-b453-5a855b69bf2e"  # Substitua pelo ID de assinatura correto
    $allMachines = Get-AllMachines

    foreach ($machine in $allMachines) {
        $resourceGroup = $machine.ResourceGroupName
        $machineName = $machine.Name

        Write-Host "`nMáquina: ${machineName}"
        
        try {
            if ($machine.Type -eq "Microsoft.Compute/virtualMachines") {
                $resourceUri = "/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Compute/virtualMachines/${machineName}"
            }
            elseif ($machine.Type -like "*HybridCompute/machines") {
                $resourceUri = "/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.HybridCompute/machines/${machineName}"
            }
            else {
                throw "Tipo de máquina desconhecido: ${machine.Type}"
            }

            $associations = Get-AzDataCollectionRuleAssociation -ResourceUri $resourceUri

            if ($associations) {
                Write-Host "DCRs associadas:"
                foreach ($association in $associations) {
                    $dcrDetails = Get-AzDataCollectionRule -ResourceId $association.DataCollectionRuleId
                    Write-Host "- ${dcrDetails.Name}"
                }
            }
            else {
                Write-Host "Nenhuma DCR associada."
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warning "Erro ao listar DCRs para máquina ${machineName}: ${errorMessage}"
        }
    }
}

# Menu de opções atualizado
function Show-MainMenu {
    Write-Host "`n========== MENU PRINCIPAL ==========`n"
    Write-Host "Escolha uma opção:"
    Write-Host "1 - Adicionar máquinas na DCR"
    Write-Host "2 - Remover máquinas da DCR"
    Write-Host "3 - Remover agentes do ARC"
    Write-Host "4 - Remover extensão AMA"
    Write-Host "5 - Listar DCRs das máquinas"
    Write-Host "6 - Sair"
    
    $option = Read-Host "Digite o número da opção"
    return $option
}

# Loop principal
$continue = $true
while ($continue) {
    $option = Show-MainMenu
    
    switch ($option) {
        1 {
            Add-MachinesToDCR
        }
        2 {
            Remove-MachinesFromDCR
        }
        3 {
            Remove-AgentsFromARC
        }
        4 {
            $osOption = Read-Host "Escolha o tipo de SO (Windows/Linux)"
            Remove-AMAExtension -osType $osOption
        }
        5 {
            Get-MachineDCRs
        }
        6 {
            $continue = $false
            Write-Host "Finalizando script..."
        }
        default {
            Write-Host "Opção inválida! Tente novamente."
        }
    }
}                        