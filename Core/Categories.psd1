# NetRing menu categories.
# The order of this list is the order (and the number) in the main menu, so
# numbers stay the same when modules are added. A module refers to a category
# with its Key in module.psd1, for example: Category = 'connectivity'.
# Modules with an unknown category end up in an extra category 'Other'.
@{
    Categories = @(
        @{ Key = 'local';        Name = 'This machine' }
        @{ Key = 'discovery';    Name = 'Discovery' }
        @{ Key = 'connectivity'; Name = 'Connectivity' }
        @{ Key = 'dns';          Name = 'DNS' }
        @{ Key = 'services';     Name = 'Services' }
        @{ Key = 'web';          Name = 'Web' }
        @{ Key = 'calculators';  Name = 'Calculators' }
        @{ Key = 'security';     Name = 'Security' }
    )
}
