# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#
# PSRule.Rules.Azure module
#

$m = Import-Module 'Az.Resources' -MinimumVersion 5.6.0 -Global -ErrorAction SilentlyContinue -PassThru;
if ($Null -eq $m) {
    Write-Warning -Message "To use PSRule for Azure export cmdlets please install Az.Resources.";
}

Set-StrictMode -Version latest;

[PSRule.Rules.Azure.Configuration.PSRuleOption]::UseExecutionContext($ExecutionContext);

#
# Localization
#

#
# Public functions
#

#region Public functions

# .ExternalHelp PSRule.Rules.Azure-help.xml
function Export-AzRuleData {
    [CmdletBinding(SupportsShouldProcess = $True, DefaultParameterSetName = 'Default')]
    [OutputType([System.IO.FileInfo])]
    [OutputType([PSObject])]
    param (
        [Parameter(Position = 0, Mandatory = $False)]
        [String]$OutputPath = $PWD,

        # Filter by Subscription name or id
        [Parameter(Mandatory = $False, ParameterSetName = 'Default')]
        [String[]]$Subscription = $Null,

        # Filter by Tenant id
        [Parameter(Mandatory = $False, ParameterSetName = 'Default')]
        [String[]]$Tenant = $Null,

        # Filter by Resource Group name
        [Parameter(Mandatory = $False)]
        [String[]]$ResourceGroupName = $Null,

        # Filter by Tag
        [Parameter(Mandatory = $False)]
        [Hashtable]$Tag,

        [Parameter(Mandatory = $False)]
        [Switch]$PassThru = $False,

        [Parameter(Mandatory = $False, ParameterSetName = 'All')]
        [Switch]$All = $False
    )
    begin {
        Write-Verbose -Message "[Export-AzRuleData] BEGIN::";
    }
    process {
        # Get subscriptions
        $context = FindAzureContext -Subscription $Subscription -Tenant $Tenant -All:$All -Verbose:$VerbosePreference;

        if ($Null -eq $context) {
            return;
        }
        if (!(Test-Path -Path $OutputPath)) {
            if ($PSCmdlet.ShouldProcess('Create output directory', $OutputPath)) {
                $Null = New-Item -Path $OutputPath -ItemType Directory -Force;
            }
        }

        $getParams = @{ };
        $filterParams = @{ };

        if ($PSBoundParameters.ContainsKey('Tag')) {
            $getParams['Tag'] = $Tag;
        }
        if ($PSBoundParameters.ContainsKey('ResourceGroupName')) {
            $getParams['ResourceGroupName'] = $ResourceGroupName;
            $filterParams['ResourceGroupName'] = $ResourceGroupName;
        }

        foreach ($c in $context) {
            Write-Verbose -Message "[Export] -- Using subscription: $($c.Subscription.Name)";
            $filePath = Join-Path -Path $OutputPath -ChildPath "$($c.Subscription.Id).json";
            GetAzureResource @getParams -Context $c -Verbose:$VerbosePreference `
            | FilterAzureResource @filterParams -Verbose:$VerbosePreference `
            | ExportAzureResource -Path $filePath -PassThru $PassThru -Verbose:$VerbosePreference;
        }
    }
    end {
        Write-Verbose -Message "[Export-AzRuleData] END::";
    }
}

# .ExternalHelp PSRule.Rules.Azure-help.xml
function Export-AzRuleTemplateData {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    [OutputType([PSObject])]
    param (
        [Parameter(Position = 0, Mandatory = $False)]
        [String]$Name,

        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]$TemplateFile,

        [Parameter(Mandatory = $False, ValueFromPipelineByPropertyName = $True)]
        [Alias('TemplateParameterFile')]
        [String[]]$ParameterFile,

        [Parameter(Mandatory = $False)]
        [Alias('ResourceGroupName')]
        [PSRule.Rules.Azure.Configuration.ResourceGroupReference]$ResourceGroup,

        [Parameter(Mandatory = $False)]
        [PSRule.Rules.Azure.Configuration.SubscriptionReference]$Subscription,

        [Parameter(Mandatory = $False)]
        [String]$OutputPath = $PWD,

        [Parameter(Mandatory = $False)]
        [Switch]$PassThru = $False
    )
    begin {
        Write-Verbose -Message '[Export-AzRuleTemplateData] BEGIN::';
        if ($MyInvocation.InvocationName -eq 'Export-AzTemplateRuleData') {
            Write-Warning -Message "The cmdlet 'Export-AzTemplateRuleData' is has been renamed to 'Export-AzRuleTemplateData'. Use of 'Export-AzTemplateRuleData' is deprecated and will be removed in the next major version."
        }

        $Option = [PSRule.Rules.Azure.Configuration.PSRuleOption]::FromFileOrDefault($PWD);
        $Option.Output.Path = $OutputPath;

        # Build the pipeline
        $builder = [PSRule.Rules.Azure.Pipeline.PipelineBuilder]::Template($Option);
        $builder.Deployment($Name);
        $builder.PassThru($PassThru);

        # Bind to subscription context
        if ($PSBoundParameters.ContainsKey('Subscription')) {
            $subscriptionOption = GetSubscription -InputObject $Subscription -ErrorAction SilentlyContinue;
            if ($Null -ne $subscriptionOption) {
                $builder.Subscription($subscriptionOption);
            }
        }
        # Bind to resource group
        if ($PSBoundParameters.ContainsKey('ResourceGroup')) {
            $resourceGroupOption = GetResourceGroup -InputObject $ResourceGroup -ErrorAction SilentlyContinue;
            if ($Null -ne $resourceGroupOption) {
                $builder.ResourceGroup($resourceGroupOption);
            }
        }

        $builder.UseCommandRuntime($PSCmdlet);
        $builder.UseExecutionContext($ExecutionContext);
        try {
            $pipeline = $builder.Build();
            $pipeline.Begin();
        }
        catch {
            $pipeline.Dispose();
        }
    }
    process {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $source = [PSRule.Rules.Azure.Pipeline.TemplateSource]::new($TemplateFile, $ParameterFile);
                $pipeline.Process($source);
            }
            catch {
                $pipeline.Dispose();
                throw;
            }
        }
    }
    end {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $pipeline.End();
            }
            finally {
                $pipeline.Dispose();
            }
        }
        Write-Verbose -Message '[Export-AzRuleTemplateData] END::';
    }
}

# .ExternalHelp PSRule.Rules.Azure-help.xml
function Get-AzRuleTemplateLink {
    [CmdletBinding()]
    [OutputType([PSRule.Rules.Azure.Data.Metadata.ITemplateLink])]
    param (
        [Parameter(Position = 1, Mandatory = $False, ValueFromPipelineByPropertyName = $True)]
        [Alias('f', 'TemplateParameterFile', 'FullName')]
        [SupportsWildcards()]
        [String[]]$InputPath = '*.parameters.json',

        [Parameter(Mandatory = $False)]
        [Switch]$SkipUnlinked,

        [Parameter(Position = 0, Mandatory = $False)]
        [Alias('p')]
        [String]$Path = $PWD
    )
    begin {
        Write-Verbose -Message '[Get-AzRuleTemplateLink] BEGIN::';

        # Build the pipeline
        $builder = [PSRule.Rules.Azure.Pipeline.PipelineBuilder]::TemplateLink($Path);
        $builder.SkipUnlinked($SkipUnlinked);
        $builder.UseCommandRuntime($PSCmdlet);
        $builder.UseExecutionContext($ExecutionContext);
        $pipeline = $builder.Build();
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $pipeline.Begin();
            }
            catch {
                $pipeline.Dispose();
                throw;
            }
        }
    }
    process {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                foreach ($p in $InputPath) {
                    $pipeline.Process($p);
                }
            }
            catch {
                $pipeline.Dispose();
                throw;
            }
        }
    }
    end {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $pipeline.End();
            }
            finally {
                $pipeline.Dispose();
            }
        }
        Write-Verbose -Message '[Get-AzRuleTemplateLink] END::';
    }
}

function Export-AzPolicyAssignmentData {
    [CmdletBinding(SupportsShouldProcess = $True, DefaultParameterSetName = 'Default')]
    [OutputType([System.IO.FileInfo])]
    [OutputType([PSObject])]
    param (
        # Name of policy assignment
        [Parameter(ParameterSetName = 'Name', Mandatory = $False)]
        [String]$Name,

        # Fully qualified resource ID of policy assignment
        [Parameter(ParameterSetName = 'Id', Mandatory = $True)]
        [Alias('AssignmentId')]
        [String]$Id,

        # Specifies assignment policy scope
        [Parameter(ParameterSetName = 'Name', Mandatory = $False)]
        [Parameter(ParameterSetName = 'IncludeDescendent', Mandatory = $False)]
        [String]$Scope,

        # Specifies the policy definition ID of the policy assignment
        [Parameter(ParameterSetName = 'Name', Mandatory = $False)]
        [Parameter(ParameterSetName = 'Id', Mandatory = $False)]
        [String]$PolicyDefinitionId,

        # Include all assignments related to given scope
        [Parameter(ParameterSetName = 'IncludeDescendent', Mandatory = $True)]
        [Switch]$IncludeDescendent = $False,

        [Parameter(Mandatory = $False)]
        [String]$OutputPath = $PWD,

        [Parameter(Mandatory = $False)]
        [Switch]$PassThru = $False
    )
    begin {
        Write-Verbose -Message '[Export-AzPolicyAssignmentData] BEGIN::';
    }
    process {
        $context = GetAzureContext -ErrorAction SilentlyContinue

        if ($Null -eq $context) {
            Write-Error -Message 'Could not find an existing context. Use Connect-AzAccount to establish a PowerShell context with Azure.';
            return;
        }

        if (!(Test-Path -Path $OutputPath)) {
            if ($PSCmdlet.ShouldProcess('Create output directory', $OutputPath)) {
                $Null = New-Item -Path $OutputPath -ItemType Directory -Force;
            }
        }

        $getParams = @{ };

        Write-Verbose -Message "Parameter Set: $($PSCmdlet.ParameterSetName)";

        if ($PSCmdlet.ParameterSetName -eq 'Name') {
            if ($PSBoundParameters.ContainsKey('Name')) {
                $getParams['Name'] = $Name;
            }

            if ($PSBoundParameters.ContainsKey('PolicyDefinitionId')) {
                $getParams['PolicyDefinitionId'] = $PolicyDefinitionId;
            }
    
            if ($PSBoundParameters.ContainsKey('Scope')) {
                $getParams['Scope'] = $Scope;
            }
            else {
                $getParams['Scope'] = GetDefaultSubscriptionScope -Context $context
            }

            Write-Verbose -Message "Scope: $($getParams['Scope'])";
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'Id') {
            $getParams['Id'] = $Id;

            if ($PSBoundParameters.ContainsKey('PolicyDefinitionId')) {
                $getParams['PolicyDefinitionId'] = $PolicyDefinitionId;
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'IncludeDescendent') {
            $getParams['IncludeDescendent'] = $IncludeDescendent;

            if ($PSBoundParameters.ContainsKey('Scope')) {
                $getParams['Scope'] = $Scope;
            }
            else {
                $getParams['Scope'] = GetDefaultSubscriptionScope -Context $context
            }
        }

        Write-Verbose -Message "[Export] -- Using subscription: $($context.Subscription.Name)";
        $filePath = Join-Path -Path $OutputPath -ChildPath "$($context.Subscription.Id).assignment.json";
        Get-AzPolicyAssignment @getParams -Verbose:$VerbosePreference `
        | ExpandPolicyAssignment -Context $context -Verbose:$VerbosePreference `
        | ExportAzureResource -Path $filePath -PassThru $PassThru -Verbose:$VerbosePreference;
    }
    end {
        Write-Verbose -Message "[Export-AzPolicyAssignmentData] END::";
    }
}

function Export-AzPolicyAssignmentRuleData {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([System.IO.FileInfo])]
    [OutputType([PSObject])]
    param (
        # Name of Policy assignment
        [Parameter(Mandatory = $False)]
        [String]$Name,

        # Assignment file path
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]$AssignmentFile,

        [Parameter(Mandatory = $False)]
        [Alias('ResourceGroupName')]
        [PSRule.Rules.Azure.Configuration.ResourceGroupReference]$ResourceGroup,

        [Parameter(Mandatory = $False)]
        [PSRule.Rules.Azure.Configuration.SubscriptionReference]$Subscription,

        [Parameter(Mandatory = $False)]
        [String]$OutputPath = $PWD,

        [Parameter(Mandatory = $False)]
        [String]$RulePrefix,

        [Parameter(Mandatory = $False)]
        [Switch]$PassThru = $False
    )
    begin {
        Write-Verbose -Message '[Export-AzPolicyAssignmentRuleData] BEGIN::';

        $option = [PSRule.Rules.Azure.Configuration.PSRuleOption]::FromFileOrDefault($PWD);
        $option.Output.Path = $OutputPath;

        if ($PSBoundParameters.ContainsKey('RulePrefix')) {
            $option.Configuration.PolicyRulePrefix = $RulePrefix
        }

        # Build the pipeline
        $builder = [PSRule.Rules.Azure.Pipeline.PipelineBuilder]::Assignment($option);
        $builder.Assignment($Name);
        $builder.PassThru($PassThru);

        # Bind to subscription context
        if ($PSBoundParameters.ContainsKey('Subscription')) {
            $subscriptionOption = GetSubscription -InputObject $Subscription -ErrorAction SilentlyContinue;
            if ($Null -ne $subscriptionOption) {
                $builder.Subscription($subscriptionOption);
            }
        }
        # Bind to resource group
        if ($PSBoundParameters.ContainsKey('ResourceGroup')) {
            $resourceGroupOption = GetResourceGroup -InputObject $ResourceGroup -ErrorAction SilentlyContinue;
            if ($Null -ne $resourceGroupOption) {
                $builder.ResourceGroup($resourceGroupOption);
            }
        }

        $builder.UseCommandRuntime($PSCmdlet);
        $builder.UseExecutionContext($ExecutionContext);
        try {
            $pipeline = $builder.Build();
            $pipeline.Begin();
        }
        catch {
            $pipeline.Dispose();
        }
    }
    process {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $source = [PSRule.Rules.Azure.Pipeline.PolicyAssignmentSource]::new($AssignmentFile);
                $pipeline.Process($source);
            }
            catch {
                $pipeline.Dispose();
                throw;
            }
        }
    }
    end {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $pipeline.End();
            }
            finally {
                $pipeline.Dispose();
            }
        }
        Write-Verbose -Message '[Export-AzPolicyAssignmentRuleData] END::';
    }
}

function Get-AzPolicyAssignmentDataSource {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([PSRule.Rules.Azure.Pipeline.PolicyAssignmentSource])]
    param (
        [Parameter(Mandatory = $False, ValueFromPipelineByPropertyName = $True)]
        [Alias('f', 'AssignmentFile', 'FullName')]
        [SupportsWildcards()]
        [String[]]$InputPath = '*.assignment.json',

        [Parameter(Mandatory = $False)]
        [Alias('p')]
        [String]$Path = $PWD
    )
    begin {
        Write-Verbose -Message '[Get-AzPolicyAssignmentDataSource] BEGIN::';

        # Build the pipeline
        $builder = [PSRule.Rules.Azure.Pipeline.PipelineBuilder]::AssignmentSearch($Path);
        $builder.UseCommandRuntime($PSCmdlet);
        $builder.UseExecutionContext($ExecutionContext);
        $pipeline = $builder.Build();
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $pipeline.Begin();
            }
            catch {
                $pipeline.Dispose();
                throw;
            }
        }
    }
    process {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                foreach ($p in $InputPath) {
                    $pipeline.Process($p);
                }
            }
            catch {
                $pipeline.Dispose();
                throw;
            }
        }
    }
    end {
        if ($Null -ne (Get-Variable -Name pipeline -ErrorAction SilentlyContinue)) {
            try {
                $pipeline.End();
            }
            finally {
                $pipeline.Dispose();
            }
        }
        Write-Verbose -Message '[Get-AzPolicyAssignmentDataSource] END::';
    }
}

#endregion Public functions

#
# Helper functions
#

function GetDefaultSubscriptionScope {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        return [string]::Concat('/subscriptions/', $context.Subscription.Id);
    }
}

function GetResourceGroup {
    [CmdletBinding()]
    [OutputType([PSRule.Rules.Azure.Configuration.ResourceGroupOption])]
    param (
        [Parameter(Mandatory = $True)]
        [PSRule.Rules.Azure.Configuration.ResourceGroupReference]$InputObject
    )
    process {
        $result = $InputObject.ToResourceGroupOption();
        if ($InputObject.FromName) {
            $o = Get-AzResourceGroup -Name $InputObject.Name -ErrorAction SilentlyContinue;
            if ($Null -ne $o) {
                $result.Name = $o.ResourceGroupName
                $result.Location = $o.Location
                $result.ManagedBy = $o.ManagedBy
                $result.Properties.ProvisioningState = $o.ProvisioningState
                $result.Tags = $o.Tags
            }
        }
        return $result;
    }
}

function GetSubscription {
    [CmdletBinding()]
    [OutputType([PSRule.Rules.Azure.Configuration.SubscriptionOption])]
    param (
        [Parameter(Mandatory = $True)]
        [PSRule.Rules.Azure.Configuration.SubscriptionReference]$InputObject
    )
    process {
        $result = $InputObject.ToSubscriptionOption();
        if ($InputObject.FromName) {
            $o = (Set-AzContext -Subscription $InputObject.DisplayName -ErrorAction SilentlyContinue).Subscription;
            if ($Null -ne $o) {
                $result.DisplayName = $o.Name
                $result.SubscriptionId = $o.SubscriptionId
                $result.State = $o.State
                $result.TenantId = $o.TenantId
            }
        }
        return $result;
    }
}

function FindAzureContext {
    [CmdletBinding()]
    [OutputType([Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer[]])]
    param (
        [Parameter(Mandatory = $False)]
        [String[]]$Subscription = $Null,

        [Parameter(Mandatory = $False)]
        [String[]]$Tenant = $Null,

        [Parameter(Mandatory = $False)]
        [System.Boolean]$All = $False
    )
    process {
        $listAvailable = $False;
        if ($Null -ne $Subscription -or $Null -ne $Tenant -or $All) {
            $listAvailable = $True;
        }

        # Get subscription contexts
        $context = @(GetAzureContext -ListAvailable:$listAvailable);
        if ($Null -eq $context -and $context.Length -gt 0) {
            Write-Error -Message 'Could not find an existing context. Use Connect-AzAccount to establish a PowerShell context with Azure.';
            return;
        }

        Write-Verbose "[Context] -- Found ($($context.Length)) subscription contexts";
        $filteredContext = @($context | ForEach-Object -Process {
                if (
                ($Null -eq $Tenant -or $Tenant.Length -eq 0 -or ($_.Tenant.Id -in $Tenant)) -and
                ($Null -eq $Subscription -or $Subscription.Length -eq 0 -or ($_.Subscription.Id -in $Subscription) -or ($_.Subscription.Name -in $Subscription))
                ) {
                    $_;
                    Write-Verbose "[Context] -- Using subscription: $($_.Subscription.Name)";
                }
            })
        Write-Verbose "[Context] -- Using [$($filteredContext.Length)/$($context.Length)] subscription contexts";
        return $filteredContext;
    }
}

function GetAzureContext {
    [CmdletBinding()]
    [OutputType([Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer[]])]
    param (
        [Parameter(Mandatory = $False)]
        [System.Boolean]$ListAvailable = $False
    )
    process {
        $getParams = @{ };
        if ($ListAvailable) {
            $getParams['ListAvailable'] = $True;
        }

        # Get contexts
        return Get-AzContext @getParams;
    }
}

function GetAzureResource {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param (
        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context,

        [Parameter(Mandatory = $False)]
        [Hashtable]$Tag,

        [Parameter(Mandatory = $False)]
        [String[]]$ResourceGroupName = $Null
    )
    begin {
        $watch = New-Object -TypeName System.Diagnostics.Stopwatch;
    }
    process {
        $resourceParams = @{ };
        $rgParams = @{ };

        if ($PSBoundParameters.ContainsKey('Tag')) {
            $resourceParams['Tag'] = $Tag;
            $rgParams['Tag'] = $Tag;
        }

        try {
            Write-Verbose -Message "[Export] -- Getting Azure resources";
            $watch.Restart();

            if ($PSBoundParameters.ContainsKey('ResourceGroupName')) {
                foreach ($rg in $ResourceGroupName) {
                    Write-Verbose -Message "[Export] -- Getting Azure resources for Resource Group: $rg";
                    Get-AzResource @resourceParams -ResourceGroupName $rg -ExpandProperties -ODataQuery "SubscriptionId EQ '$($Context.DefaultContext.Subscription.Id)'" -DefaultProfile $Context `
                    | ExpandResource -Context $Context -Verbose:$VerbosePreference;
                    Get-AzResourceGroup @rgParams -Name $rg -DefaultProfile $Context |
                    SetResourceType 'Microsoft.Resources/resourceGroups' |
                    ExpandResource -Context $Context -Verbose:$VerbosePreference;
                }
            }
            else {
                Get-AzResource @resourceParams -ExpandProperties -DefaultProfile $Context |
                ExpandResource -Context $Context -Verbose:$VerbosePreference;
                Get-AzResourceGroup @rgParams -DefaultProfile $Context |
                SetResourceType 'Microsoft.Resources/resourceGroups' |
                ExpandResource -Context $Context -Verbose:$VerbosePreference;
            }

            Write-Verbose -Message "[Export] -- Azure resources exported in [$($watch.ElapsedMilliseconds) ms]";
            $watch.Restart();

            Write-Verbose -Message "[Export] -- Getting Azure subscription: $($Context.DefaultContext.Subscription.Id)";
            Get-AzSubscription -SubscriptionId $Context.DefaultContext.Subscription.Id |
            SetResourceType 'Microsoft.Subscription' |
            ExpandResource -Context $Context -Verbose:$VerbosePreference;

            Write-Verbose -Message "[Export] -- Azure subscription exported in [$($watch.ElapsedMilliseconds) ms]";
        }
        finally {
            $watch.Stop();
        }
    }
}

function FilterAzureResource {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param (
        [Parameter(Mandatory = $False)]
        [String[]]$ResourceGroupName = $Null,

        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$InputObject
    )
    process {
        if (($Null -eq $ResourceGroupName) -or ($InputObject.ResourceType -eq 'Microsoft.Subscription') -or (@($InputObject.PSObject.Properties | Where-Object { $_.Name -eq 'ResourceGroupName' }).Length -eq 0)) {
            return $InputObject;
        }
        elseif ($InputObject.ResourceGroupName -in $ResourceGroupName) {
            return $InputObject;
        }
    }
}

function ExportAzureResource {
    [CmdletBinding(SupportsShouldProcess = $True)]
    [OutputType([System.IO.FileInfo])]
    [OutputType([PSObject])]
    param (
        [Parameter(Mandatory = $True)]
        [String]$Path,

        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$InputObject,

        [Parameter(Mandatory = $False)]
        [System.Boolean]$PassThru = $False
    )
    begin {
        $resources = @();
    }
    process {
        if ($PassThru) {
            $InputObject;
        }
        else {
            # Collect passed through resources
            $resources += $InputObject;
        }
    }
    end {
        $watch = New-Object -TypeName System.Diagnostics.Stopwatch;
        Write-Verbose -Message "[Export] -- Exporting to JSON";
        $watch.Restart();

        if (!$PassThru) {
            # Save to JSON
            ConvertTo-Json -InputObject $resources -Depth 100 | Set-Content -Path $Path;
            Get-Item -Path $Path;
        }
        $watch.Stop();
        Write-Verbose -Message "[Export] -- Exported to JSON in [$($watch.ElapsedMilliseconds) ms]";
    }
}

function GetSubResource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context,

        [Parameter(Mandatory = $True)]
        [String]$ResourceType,

        [Parameter(Mandatory = $True)]
        [String]$ApiVersion
    )
    process {
        $getParams = @{
            Name              = $Resource.Name
            ResourceType      = $ResourceType
            ResourceGroupName = $Resource.ResourceGroupName
            DefaultProfile    = $Context
            ApiVersion        = $ApiVersion
        }
        try {
            Get-AzResource @getParams -ExpandProperties;
        }
        catch {
            Write-Warning -Message "Failed to read $($Resource.Name): $ResourceType";
        }
    }
}

function GetResourceById {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [PSObject]$ResourceId,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context,

        [Parameter(Mandatory = $True)]
        [String]$ApiVersion
    )
    process {
        $getParams = @{
            ResourceId     = $ResourceId
            DefaultProfile = $Context
            ApiVersion     = $ApiVersion
        }
        try {
            Get-AzResource @getParams -ExpandProperties;
        }
        catch {
            Write-Warning -Message "Failed to read $ResourceId";
        }
    }
}

function GetSubResourceId {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context,

        [Parameter(Mandatory = $True)]
        [String]$Property,

        [Parameter(Mandatory = $True)]
        [String]$ApiVersion
    )
    process {
        $getParams = @{
            ResourceId     = [String]::Concat($Resource.Id, '/', $Property)
            DefaultProfile = $Context
            ApiVersion     = $ApiVersion
        }
        try {
            Get-AzResource @getParams -ExpandProperties;
        }
        catch {
            Write-Warning -Message "Failed to read $($Resource.Name): $Property";
        }
    }
}

function GetRestProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context,

        [Parameter(Mandatory = $True)]
        [String]$Property,

        [Parameter(Mandatory = $True)]
        [String]$ApiVersion
    )
    process {
        try {
            $token = GetRestToken -Context $Context;
            $getParams = @{
                Uri     = [String]::Concat('https://management.azure.com', $Resource.Id, '/', $Property, '?api-version=', $ApiVersion)
                Headers = @{
                    Authorization = "Bearer $($token)"
                }
            }
            Invoke-RestMethod -Method Get @getParams -UseBasicParsing -Verbose:$VerbosePreference;
        }
        catch {
            Write-Warning -Message "Failed to read $($Resource.Name): $Property";
        }
    }
}

function GetRestToken {
    [CmdletBinding()]
    [OutputType([String])]
    param (
        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        return ($Context.DefaultContext.TokenCache.ReadItems() | Where-Object {
                $_.TenantId -eq $Context.DefaultContext.Tenant.Id -and
                $_.Resource -eq 'https://management.core.windows.net/' -and
                $_.Authority -eq "https://login.windows.net/$($Context.DefaultContext.Tenant.Id)/"
            }).AccessToken;
    }
}

function GetSubProvider {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context,

        [Parameter(Mandatory = $True)]
        [String]$ResourceType,

        [Parameter(Mandatory = $True)]
        [String]$ApiVersion,

        [Parameter(Mandatory = $False)]
        [Switch]$ExpandProperties
    )
    process {
        $getParams = @{
            ResourceId     = [String]::Concat($Resource.Id, '/providers/', $ResourceType)
            DefaultProfile = $Context
            ApiVersion     = $ApiVersion
        }
        try {
            Get-AzResource @getParams -ExpandProperties:$ExpandProperties;
        }
        catch {
            Write-Warning -Message "Failed to read $($Resource.Name): $ResourceType";
        }
    }
}

function VisitAPIManagement {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $apis += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/apis' -ApiVersion '2019-12-01';
        foreach ($api in $apis) {
            $resources += $api;
            $apiParams = @{
                Name              = "$($Resource.Name)/$($api.Name)"
                ResourceType      = 'Microsoft.ApiManagement/service/apis/policies'
                ResourceGroupName = $Resource.ResourceGroupName
                DefaultProfile    = $Context
                ApiVersion        = '2019-12-01'
            };
            $resources += Get-AzResource @apiParams;
        }

        # Add zones in from REST API because they are not included from Get-AzResource
        $apiManagementServicePrimaryZones = ((Invoke-AzRestMethod -Path "$($Resource.ResourceId)?api-version=2020-12-01" -Method GET).Content | ConvertFrom-Json).zones;
        $Resource = $Resource | Add-Member -MemberType NoteProperty -Name zones -Value $apiManagementServicePrimaryZones -PassThru;

        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/backends' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/products' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/policies' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/identityProviders' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/diagnostics' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/loggers' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/certificates' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/namedValues' -ApiVersion '2019-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ApiManagement/service/portalsettings' -ApiVersion '2019-12-01';
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitSqlServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $sqlServer = $resource;
        $resources = @();

        # Get SQL Server firewall rules
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Sql/servers/firewallRules' -ApiVersion '2015-05-01-preview';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Sql/servers/administrators' -ApiVersion '2014-04-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Sql/servers/securityAlertPolicies' -ApiVersion '2017-03-01-preview';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Sql/servers/vulnerabilityAssessments' -ApiVersion '2018-06-01-preview';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Sql/servers/auditingSettings' -ApiVersion '2017-03-01-preview';
        $sqlServer | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitSqlDatabase {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $getParams = @{
            ResourceGroupName = $Resource.ResourceGroupName
            DefaultProfile    = $Context
            ErrorAction       = 'SilentlyContinue'
        }
        $idParts = $Resource.ResourceId.Split('/');
        $serverName = $idParts[-3];
        $resourceName = "$serverName/$($Resource.Name)";
        $resources += Get-AzResource @getParams -Name $resourceName -ResourceType 'Microsoft.Sql/servers/databases/dataMaskingPolicies' -ApiVersion '2014-04-01' -ExpandProperties
        $resources += Get-AzResource @getParams -Name $resourceName -ResourceType 'Microsoft.Sql/servers/databases/transparentDataEncryption' -ApiVersion '2014-04-01' -ExpandProperties;
        $resources += Get-AzResource @getParams -Name $resourceName -ResourceType 'Microsoft.Sql/servers/databases/connectionPolicies' -ApiVersion '2014-04-01' -ExpandProperties;
        $resources += Get-AzResource @getParams -Name $resourceName -ResourceType 'Microsoft.Sql/servers/databases/geoBackupPolicies' -ApiVersion '2014-04-01' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitPostgreSqlServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $sqlServer = $resource;
        $resources = @();

        # Get Postgre SQL Server firewall rules
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.DBforPostgreSQL/servers/firewallRules' -ApiVersion '2017-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.DBforPostgreSQL/servers/securityAlertPolicies' -ApiVersion '2017-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.DBforPostgreSQL/servers/configurations' -ApiVersion '2017-12-01';
        $sqlServer | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitMySqlServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $sqlServer = $resource;
        $resources = @();

        # Get MySQL Server firewall rules
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.DBforMySQL/servers/firewallRules' -ApiVersion '2017-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.DBforMySQL/servers/securityAlertPolicies' -ApiVersion '2017-12-01';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.DBforMySQL/servers/configurations' -ApiVersion '2017-12-01';
        $sqlServer | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitSqlManagedInstance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $sqlMI = $resource;
        $resources = @();

        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.Sql/managedInstances/securityAlertPolicies' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2017-03-01-preview' -ExpandProperties;
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.Sql/managedInstances/vulnerabilityAssessments' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2018-06-01-preview' -ExpandProperties;
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.Sql/managedInstances/administrators' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2017-03-01-preview' -ExpandProperties;
        $sqlMI | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitAutomationAccount {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $aa = $Resource
        $resources = @();
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Automation/AutomationAccounts/variables' -ApiVersion '2015-10-31';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Automation/AutomationAccounts/webhooks' -ApiVersion '2015-10-31';

        $diagnosticSettingsResourceParams = @{
            Name              = $Resource.Name
            ResourceType      = 'Microsoft.Automation/automationAccounts/providers/microsoft.insights/diagnosticSettings'
            ResourceGroupName = $Resource.ResourceGroupName
            DefaultProfile    = $Context
            ExpandProperties  = $True
            ApiVersion        = '2021-05-01-preview'
        }

        $resources += Get-AzResource @diagnosticSettingsResourceParams

        $aa | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

# function VisitDataFactoryV2 {
#     param (
#         [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
#         [PSObject]$Resource,

#         [Parameter(Mandatory = $True)]
#         [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
#     )
#     process {
#         $df = $resource;
#         $resources = @();

#         # Get linked services
#         $resources += Get-AzDataFactoryV2LinkedService -DataFactoryName $resource.Name -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context | ForEach-Object -Process {
#             $linkedService = $_;
#             $type = $linkedService.Properties.GetType().Name;
#             $linkedService.Properties.AdditionalProperties = $Null;
#             if ($Null -ne $linkedService.Properties.EncryptedCredential) {
#                 $linkedService.Properties.EncryptedCredential = $Null;
#             }

#             $linkedService | Add-Member -MemberType NoteProperty -Name 'ResourceType' -Value 'linkedServices';
#             $linkedService | Add-Member -MemberType NoteProperty -Name 'Type' -Value $type;
#             $linkedService;
#         };
#         $df | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
#     }
# }

function VisitCDNEndpoint {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += GetSubResourceId @PSBoundParameters -Property 'customdomains' -ApiVersion '2019-04-15';
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitContainerRegistry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ContainerRegistry/registries/replications' -ApiVersion '2019-12-01-preview';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ContainerRegistry/registries/webhooks' -ApiVersion '2019-12-01-preview';
        $resources += GetSubResource @PSBoundParameters -ResourceType 'Microsoft.ContainerRegistry/registries/tasks' -ApiVersion '2019-06-01-preview';
        $resources += GetRestProperty @PSBoundParameters -Property 'listUsages' -ApiVersion '2019-05-01' | SetResourceType 'Microsoft.ContainerRegistry/registries/listUsages';
        $resources += GetSubProvider @PSBoundParameters -ResourceType 'Microsoft.Security/assessments' -ApiVersion '2019-01-01-preview';
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitAKSCluster {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();

        # Only add VNET resource if AKS cluster is using Azure CNI network plugin
        # Supported network plugins: azure or kubenet
        # https://docs.microsoft.com/en-us/azure/templates/microsoft.containerservice/managedclusters?tabs=json#containerservicenetworkprofile-object
        if ($Resource.Properties.networkProfile.networkPlugin -eq 'azure') {
            $nodePools = @($Resource.Properties.agentPoolProfiles);
            foreach ($nodePool in $nodePools) {
                $vnetId = $nodePool.vnetSubnetID;
                $resources += GetResourceById -ResourceId $vnetId -ApiVersion '2020-05-01' -Context $Context;
            }
        }

        $resources += Get-AzResource -Name $Resource.Name -ResourceType 'Microsoft.ContainerService/managedClusters/providers/microsoft.insights/diagnosticSettings' -ResourceGroupName $Resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2017-05-01-preview' -ExpandProperties;

        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitPublicIP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        # Get-AzResource does not return zones, even with latest API version
        # Had to fetch the zones using ARM REST API and insert them into the resource
        # Logged an issue with Az PowerShell: https://github.com/Azure/azure-powershell/issues/15905
        $publicIp = ((Invoke-AzRestMethod -Path "$($Resource.ResourceId)?api-version=2021-02-01" -Method GET).Content | ConvertFrom-Json).PSObject.Properties['zones'];
        if ($Null -ne $publicIp) {
            $Resource | Add-Member -MemberType NoteProperty -Name zones -Value $publicIp.value -PassThru;
        }
        else {
            $Resource;
        }
    }
}

function VisitRedisCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        # Get-AzResource does not return zones, even with latest API version
        # Had to fetch the zones using ARM REST API and insert them into the resource
        # Logged an issue with Az PowerShell: https://github.com/Azure/azure-powershell/issues/15905
        $redisCacheZones = ((Invoke-AzRestMethod -Path "$($Resource.ResourceId)?api-version=2021-06-01" -Method GET).Content | ConvertFrom-Json).PSObject.Properties['zones'];
        if ($Null -ne $redisCacheZones) {
            $Resource | Add-Member -MemberType NoteProperty -Name zones -Value $redisCacheZones.value -PassThru;
        }
        else {
            $Resource;
        }
    }
}

function VisitRedisEnterpriseCache {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        # Get-AzResource does not return zones, even with latest API version
        # Had to fetch the zones using ARM REST API and insert them into the resource
        # Logged an issue with Az PowerShell: https://github.com/Azure/azure-powershell/issues/15905
        $redisEnterpriseCacheZones = ((Invoke-AzRestMethod -Path "$($Resource.ResourceId)?api-version=2021-08-01" -Method GET).Content | ConvertFrom-Json).PSObject.Properties['zones'];
        if ($Null -ne $redisEnterpriseCacheZones) {
            $Resource | Add-Member -MemberType NoteProperty -Name zones -Value $redisEnterpriseCacheZones.value -PassThru;
        }
        else {
            $Resource;
        }
    }
}

function VisitStorageAccount {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        if ($Resource.Kind -ne 'FileStorage') {
            $blobServices = @(GetSubResource @PSBoundParameters -ResourceType 'Microsoft.Storage/storageAccounts/blobServices' -ApiVersion '2019-04-01');
            foreach ($blobService in $blobServices) {
                $resources += $blobService;
                $resources += Get-AzResource -Name "$($Resource.Name)/$($blobService.Name)" -ResourceType 'Microsoft.Storage/storageAccounts/blobServices/containers' -ResourceGroupName $Resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2019-04-01' -ExpandProperties;
            }
        }
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitStorageSyncService {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += Get-AzStorageSyncServer -ParentResourceId $Resource.ResourceId -DefaultProfile $Context;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitWebApp {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $configResourceType = 'Microsoft.Web/sites/config';

        # Handle slots
        if ($Resource.ResourceType -eq 'Microsoft.Web/sites/slots') {
            $configResourceType = 'Microsoft.Web/sites/slots/config';
        }

        $resources += Get-AzResource -Name $Resource.Name -ResourceType $configResourceType -ResourceGroupName $Resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2018-11-01' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitRecoveryServices {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.RecoveryServices/vaults/replicationRecoveryPlans' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2018-07-10' -ExpandProperties;
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.RecoveryServices/vaults/replicationAlertSettings' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2018-07-10' -ExpandProperties;
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.RecoveryServices/vaults/backupstorageconfig/vaultstorageconfig' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2018-07-10' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitVirtualMachine {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $networkInterfaceId = $Resource.Properties.networkProfile.networkInterfaces.id;
        foreach ($id in $networkInterfaceId) {
            $resources += Get-AzResource -ResourceId $id -ExpandProperties -DefaultProfile $Context;
        }
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitKeyVault {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.KeyVault/vaults/providers/microsoft.insights/diagnosticSettings' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2017-05-01-preview' -ExpandProperties;

        $resources += GetResourceById -ResourceId "$($Resource.Id)/keys" -Context $Context -ApiVersion '2021-11-01-preview';

        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitFrontDoor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        # Patch Front Door properties not fully returned from the default API version
        $Resource = Get-AzResource -Name $resource.Name -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ResourceType 'Microsoft.Network/frontdoors' -ExpandProperties -ApiVersion '2018-08-01';

        $resources = @();
        $resources += Get-AzResource -Name $resource.Name -ResourceType 'Microsoft.Network/frontdoors/providers/microsoft.insights/diagnosticSettings' -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ApiVersion '2017-05-01-preview' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitFrontDoorWAFPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        # Patch Front Door WAF policy properties not fully returned from the default API version
        $Resource = Get-AzResource -Name $resource.Name -ResourceGroupName $resource.ResourceGroupName -DefaultProfile $Context -ResourceType 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies' -ExpandProperties -ApiVersion '2019-10-01';
        $Resource;
    }
}

function VisitNetworkConnection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        # Patch connections
        if (@($Resource.Properties.PSObject.Properties.Match('sharedKey')).Length -gt 0) {
            $Resource.Properties.sharedKey = "*** MASKED ***";
        }
        $Resource;
    }
}

function VisitSubscription {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += Get-AzRoleAssignment -DefaultProfile $Context -IncludeClassicAdministrators | SetResourceType 'Microsoft.Authorization/roleAssignments';
        $resources += Get-AzResource -DefaultProfile $Context -ApiVersion '2017-08-01-preview' -ResourceId "/subscriptions/$($Resource.Id)/providers/Microsoft.Security/autoProvisioningSettings";
        $resources += Get-AzResource -DefaultProfile $Context -ApiVersion '2017-08-01-preview' -ResourceId "/subscriptions/$($Resource.Id)/providers/Microsoft.Security/securityContacts";
        $resources += Get-AzResource -DefaultProfile $Context -ApiVersion '2018-06-01' -ResourceId "/subscriptions/$($Resource.Id)/providers/Microsoft.Security/pricings";
        $resources += Get-AzResource -DefaultProfile $Context -ApiVersion '2019-06-01' -ResourceId "/subscriptions/$($Resource.Id)/providers/Microsoft.Authorization/policyAssignments";
        $resources += Get-AzResource -DefaultProfile $Context -ResourceType 'microsoft.insights/activityLogAlerts' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;

        Get-AzPolicyDefinition -Custom -DefaultProfile $Context;
        Get-AzPolicySetDefinition -Custom -DefaultProfile $Context;
    }
}

function VisitResourceGroup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $resources += Get-AzRoleAssignment -DefaultProfile $Context -Scope $Resource.ResourceId `
        | Where-Object { $_.Scope.StartsWith($Resource.ResourceId) } `
        | SetResourceType 'Microsoft.Authorization/roleAssignments';
        $resources += Get-AzResourceLock -DefaultProfile $Context -ResourceGroupName $Resource.ResourceGroupName | SetResourceType 'Microsoft.Authorization/locks';
        $Resource `
        | Add-Member -MemberType NoteProperty -Name Name -Value $Resource.ResourceGroupName -PassThru `
        | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitDataExplorerCluster {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $getParams = @{
            ResourceGroupName = $Resource.ResourceGroupName
            DefaultProfile    = $Context
            ErrorAction       = 'SilentlyContinue'
        }
        $resources += Get-AzResource @getParams -Name $Resource.Name -ResourceType 'Microsoft.Kusto/clusters/databases' -ApiVersion '2021-08-27' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitEventHubNamespaces {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $getParams = @{
            ResourceGroupName = $Resource.ResourceGroupName
            DefaultProfile    = $Context
            ErrorAction       = 'SilentlyContinue'
        }
        $resources += Get-AzResource @getParams -Name $Resource.Name -ResourceType 'Microsoft.EventHub/namespaces/eventhubs' -ApiVersion '2021-11-01' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function VisitServiceBusNamespaces {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resources = @();
        $getParams = @{
            ResourceGroupName = $Resource.ResourceGroupName
            DefaultProfile    = $Context
            ErrorAction       = 'SilentlyContinue'
        }
        $resources += Get-AzResource @getParams -Name $Resource.Name -ResourceType 'Microsoft.ServiceBus/namespaces/queues' -ApiVersion '2021-06-01-preview' -ExpandProperties;
        $resources += Get-AzResource @getParams -Name $Resource.Name -ResourceType 'Microsoft.ServiceBus/namespaces/topics' -ApiVersion '2021-06-01-preview' -ExpandProperties;
        $Resource | Add-Member -MemberType NoteProperty -Name resources -Value $resources -PassThru;
    }
}

function ExpandPolicyAssignment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Assignment,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $policyDefinitionId = $Assignment.Properties.PolicyDefinitionId;

        Write-Verbose -Message "[Export] -- Expanding: $policyDefinitionId";

        $policyDefinitions = [System.Collections.Generic.List[PSObject]]@();

        if ($policyDefinitionId -like '*/providers/Microsoft.Authorization/policyDefinitions/*') {
            $definition = Get-AzPolicyDefinition -Id $policyDefinitionId -DefaultProfile $Context;
            $policyDefinitions.Add($definition);
        }
        elseif ($policyDefinitionId -like '*/providers/Microsoft.Authorization/policySetDefinitions/*') {
            $policySetDefinition = Get-AzPolicySetDefinition -Id $policyDefinitionId -DefaultProfile $Context;

            foreach ($definition in $policySetDefinition.Properties.PolicyDefinitions) {
                $definitionId = $definition.policyDefinitionId;
                Write-Verbose -Message "[Export] -- Expanding: $definitionId";
                $definition = Get-AzPolicyDefinition -Id $definitionId -DefaultProfile $Context;
                $policyDefinitions.Add($definition);
            }
        }

        $Assignment | Add-Member -MemberType NoteProperty -Name PolicyDefinitions -Value $policyDefinitions;

        $exemptions = @(Get-AzPolicyExemption -PolicyAssignmentIdFilter $Assignment.PolicyAssignmentId -Verbose:$VerbosePreference -DefaultProfile $Context);
        $Assignment | Add-Member -MemberType NoteProperty -Name exemptions -Value $exemptions;

        $Assignment;
    }
}

# Add additional information to resources with child resources
function ExpandResource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True)]
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer]$Context
    )
    process {
        $resourceId = '';
        if ($Resource.ResourceType -eq 'Microsoft.Subscription') {
            $resourceId = $Resource.Id;
        }
        else {
            $resourceId = $Resource.ResourceId;
        }
        Write-Verbose -Message "[Export] -- Expanding: $($resourceId)";
        switch ($Resource.ResourceType) {
            'Microsoft.ApiManagement/service' { VisitAPIManagement @PSBoundParameters; }
            'Microsoft.Automation/automationAccounts' { VisitAutomationAccount @PSBoundParameters; }
            'Microsoft.Cdn/profiles/endpoints' { VisitCDNEndpoint @PSBoundParameters; }
            'Microsoft.ContainerRegistry/registries' { VisitContainerRegistry @PSBoundParameters; }
            'Microsoft.ContainerService/managedClusters' { VisitAKSCluster @PSBoundParameters; }
            'Microsoft.Sql/servers' { VisitSqlServer @PSBoundParameters; }
            'Microsoft.Sql/servers/databases' { VisitSqlDatabase @PSBoundParameters; }
            'Microsoft.DBforPostgreSQL/servers' { VisitPostgreSqlServer @PSBoundParameters; }
            'Microsoft.DBforMySQL/servers' { VisitMySqlServer @PSBoundParameters; }
            # 'Microsoft.Sql/managedInstances' { VisitSqlManagedInstance @PSBoundParameters; }
            # 'Microsoft.DataFactory/factories' { VisitDataFactoryV2 @PSBoundParameters; }
            'Microsoft.Storage/storageAccounts' { VisitStorageAccount @PSBoundParameters; }
            # "Microsoft.StorageSync/storageSyncServices" { VisitStorageSyncService @PSBoundParameters; }
            'Microsoft.Web/sites' { VisitWebApp @PSBoundParameters; }
            'Microsoft.Web/sites/slots' { VisitWebApp @PSBoundParameters; }
            'Microsoft.RecoveryServices/vaults' { VisitRecoveryServices @PSBoundParameters; }
            'Microsoft.Compute/virtualMachines' { VisitVirtualMachine @PSBoundParameters; }
            'Microsoft.KeyVault/vaults' { VisitKeyVault @PSBoundParameters; }
            'Microsoft.Network/frontDoors' { VisitFrontDoor @PSBoundParameters; }
            'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies' { VisitFrontDoorWAFPolicy @PSBoundParameters; }
            'Microsoft.Network/connections' { VisitNetworkConnection @PSBoundParameters; }
            'Microsoft.Subscription' { VisitSubscription @PSBoundParameters; }
            'Microsoft.Resources/resourceGroups' { VisitResourceGroup @PSBoundParameters; }
            'Microsoft.Network/publicIPAddresses' { VisitPublicIP @PSBoundParameters; }
            'Microsoft.Cache/Redis' { VisitRedisCache @PSBoundParameters; }
            'Microsoft.Cache/redisEnterprise' { VisitRedisEnterpriseCache @PSBoundParameters; }
            'Microsoft.Kusto/Clusters' { VisitDataExplorerCluster @PSBoundParameters; }
            'Microsoft.EventHub/namespaces' { VisitEventHubNamespaces @PSBoundParameters; }
            'Microsoft.ServiceBus/namespaces' { VisitServiceBusNamespaces @PSBoundParameters; }
            default { $Resource; }
        }
    }
}

function SetResourceType {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [PSObject]$Resource,

        [Parameter(Mandatory = $True, Position = 0)]
        [String]$ResourceType
    )
    process {
        if ($ResourceType -eq 'Microsoft.Resources/resourceGroups') {
            $Resource = $Resource | Add-Member -MemberType NoteProperty -Name Id -Value $Resource.ResourceId -PassThru -Force;
        }
        $Resource | Add-Member -MemberType NoteProperty -Name ResourceType -Value $ResourceType -PassThru -Force;
    }
}

#
# Export module
#

New-Alias -Name 'Export-AzTemplateRuleData' -Value 'Export-AzRuleTemplateData' -Force;

Export-ModuleMember -Function @(
    'Export-AzRuleData'
    'Export-AzRuleTemplateData'
    'Get-AzRuleTemplateLink'
    'Export-AzPolicyAssignmentData'
    'Export-AzPolicyAssignmentRuleData'
    'Get-AzPolicyAssignmentDataSource'
);

Export-ModuleMember -Alias @(
    'Export-AzTemplateRuleData'
);
