use ExtUtils::MakeMaker;

WriteMakefile(
	NAME         => 'Ceni::Backend',
	VERSION_FROM => 'lib/Ceni/Backend.pm',
	(
		$] >= 5.005
		?
		        (
			ABSTRACT_FROM => 'lib/Ceni/Backend.pm',
			AUTHOR        => 'Kel Modderman <kelmo@otaku42.de>'
		        )
		: ()
	),
	EXE_FILES => [
		'bin/Ceni',
		'bin/nicinfo'
	],
);
