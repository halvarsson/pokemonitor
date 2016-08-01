#Add PushBullet API key
$API_Key = "--insert api key here--"
#Add PushBullet channel tag
$pbChannelTag = "--insert pushbullet channelname here--"
 
 #SQLite queries
 
 #Verify query
$verifyQuery = @"
SELECT ID FROM alerts WHERE Latitude = @latitude AND Longitude = @longitude AND (Expire_At > @startRange AND Expire_At < @endRange) AND Pokemon = @Pokemon
"@

 #Insert query
$insertQuery = @"
INSERT INTO alerts (Pokemon,Latitude,Longitude,Expire_At) VALUES (@Pokemon,@Latitude,@Longitude,@Expire_At) 
"@

#load assembly for sqlite
Add-Type -Path "C:\pokemonitor\System.Data.SQLite.dll"

function echo-debug ($msg)
{
	Write-host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")]" -foregroundcolor white -backgroundcolor black -nonewline; Write-host " - $msg"
}

Function Convert-FromUnixdate ($UnixDate) {
   [timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').`
   AddSeconds($UnixDate))
}

Function Convert-ToUnixDate ($dateTime)
{
	$unixEpochStart = new-object DateTime 1970,1,1,0,0,0,([DateTimeKind]::Utc)
	return [int]($dateTime.ToUniversalTime() - $unixEpochStart).TotalSeconds
}

Function PushBullet($Title, $Content){
    $Body = "type=note;title=$Title;body=$content;channel_tag=$pbChannelTag"
    #--- Create Credentials ---#
    $secpasswd = ConvertTo-SecureString " " -AsPlainText -Force # Password is blank
    $mycreds = New-Object System.Management.Automation.PSCredential ($API_Key, $secpasswd)
    #--- Send Request ---#
    Invoke-RestMethod -Credential $mycreds https://api.pushbullet.com/v2/pushes -Body $Body -Method Post
    echo-debug "Sent pushbullet notification with title: $Title "
    echo-debug "Google maps link: $content"
}

function Return-Pokemons
{
    param($lat,$long)

    $pokemonResults = @()
    $jobID = Invoke-WebRequest https://pokevision.com/map/scan/$lat/$long

    $content = ConvertFrom-Json $jobId.Content

    if ($content.status -eq 'success')
    {
        $rawJobId = $content.jobId
        echo-debug "Content: $content"
        do{
        $pkmnQuery = Invoke-WebRequest https://pokevision.com/map/data/$lat/$long/$rawJobId
        $pkmnQueryObj = ConvertFrom-Json $pkmnQuery.Content
		#Takes around 3-5s for PokeVision to return the results
        Start-Sleep -s 5
        }
        while ($pkmnQueryObj.jobStatus -eq "in_progress")
        echo-debug "pkmnQueryStatus: $($pkmnQueryObj.status)"
        $pokemons = $pkmnQueryObj.pokemon
        foreach ($pokemon in $pokemons)
        {
            if ($pokedex | where-object { $_.number -eq $pokemon.pokemonId -and $_.watchlist -eq "x"}) 
            {
            $props = @{
                ID=$pokemon.ID;
                Latitude=$pokemon.latitude;
                Longitude=$pokemon.longitude;
                GoogleMaps="https://maps.google.com/maps?q=$($pokemon.latitude),$($pokemon.Longitude)&z=19"
                Alive=$pokemon.Is_alive;
                Pokemon=($pokedex | where-object { $_.number -eq $pokemon.pokemonId }).name;
				Expire_At= $pokemon.expiration_time;
                Expire_date=(Convert-FromUnixdate $pokemon.expiration_time);
                uid=$pokemon.uid
            }

            $pokemonResults += New-Object -TypeName PSObject -Property $props
            }
        }
    }
	elseif($content.status -eq "error")
	{
		echo-debug "Error: $($content.message)"
		return $false
	}
	else
	{
		echo-debug "Other result, Status code: $($content.status) & Error message: $($content.message)"
	}
    return $pokemonResults
}


do
{
    $conn = New-Object -TypeName System.Data.SQLite.SQLiteConnection
    $conn.ConnectionString = "Data Source=C:\pokemonitor\localcache.db"
    $conn.Open()
    $pokedex = Import-Csv -Delimiter ":" -Path .\pokedex.txt -Encoding 'Unicode'
    $locations = Import-Csv -Delimiter ":" -Path .\locations.txt -Encoding 'Unicode'

    echo-debug "Processing locations..."

    foreach ($location in $locations)
    {
	    do
	    {
		    $scan = Return-Pokemons -lat $location.lat -long $location.long
		    if ($scan -eq $false)
		    {
			    echo-debug "something failed, retrying in 5s"
			    Start-Sleep 5
		    }
	    }
	    while ($scan -eq $false)
	
        if ($scan)
        {
		    echo-debug "Processing location $($location.name), total results $(@($scan).Count)"
		    echo-debug "Pokemons found: $(@($scan.Pokemon) -join ',')"
            
            foreach ($result in $scan)
            {
                    $sql = $conn.CreateCommand()
                    $sql.CommandText = $verifyQuery
                    [void]$sql.Parameters.AddWithValue("@Pokemon", $($result.Pokemon));
                    [void]$sql.Parameters.AddWithValue("@Latitude", $($result.Latitude) );
                    [void]$sql.Parameters.AddWithValue("@Longitude", $($result.Longitude));
                    [void]$sql.Parameters.AddWithValue("@StartRange", (Convert-ToUnixDate -dateTime $($result.Expire_date).AddMinutes(-5)));
				    [void]$sql.Parameters.AddWithValue("@endRange", (Convert-ToUnixDate -dateTime $($result.Expire_date).AddMinutes(5)));
                    $adapter = New-Object -TypeName System.Data.SQLite.SQLiteDataAdapter $sql
                    $data = New-Object System.Data.DataSet
                    [void]$adapter.Fill($data)
                    $dbResult = $data.tables.rows
                    if ($dbResult -eq $null)
                    {
                        echo-debug "Pokemon $($result.Pokemon) found at $($location.name)"
                        $expireDate = $($result.Expire_date - (Get-Date))
                        $expireTime = "$($expireDate.Minutes):$($expireDate.Seconds)"
                        $expireDateFormatted = Get-Date $($result.Expire_date) -Format "HH:mm"
					    PushBullet -title "$($location.name) - $($result.Pokemon) - $expireTime ($expireDateFormatted)" -content "$($result.GoogleMaps)"
                        $sql = $conn.CreateCommand()
                        $sql.CommandText = $insertQuery
                        [void]$sql.Parameters.AddWithValue("@Pokemon", $($result.Pokemon));
                        [void]$sql.Parameters.AddWithValue("@Latitude", $($result.Latitude));
                        [void]$sql.Parameters.AddWithValue("@Longitude", $($result.Longitude));
                        [void]$sql.Parameters.AddWithValue("@Expire_At", $($result.Expire_At));
                        [void]$sql.ExecuteNonQuery()
                    }
                    else
                    {
				        echo-debug "Pokemon $($result.Pokemon) found in local cache, skipping notification"
                    }
            }
        }
	    else
	    {
		    echo-debug "No pokemons found for location $($location.name)"
	    }
		#need atleast 10s between tries to avoid scan throttling by pokevision (so 5+5 seconds of waiting time)
	    Start-Sleep -s 5
    }

    $conn.Dispose()
}
while ($true)