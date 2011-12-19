#!/usr/bin/perl

#
# PostGIS - Spatial Types for PostgreSQL
# http://postgis.refractions.net
#
# Copyright (C) 2011 OpenGeo.org
# Copyright (C) 2009 Paul Ramsey <pramsey@cleverelephant.ca>
#
# This is free software; you can redistribute and/or modify it under
# the terms of the GNU General Public Licence. See the COPYING file.
#
#---------------------------------------------------------------------
#
# This script is aimed at restoring postgis data
# from a dumpfile produced by pg_dump -Fc
#
# Basically it will restore all but things known to belong
# to postgis. Will also convert some old known constructs
# into new ones.
#
# Tested on:
#
#    pg-8.4.9/pgis-2.0.0SVN => pg-8.4.9/pgis-2.0.0SVN
#    pg-9.1b3/pgis-1.5.3    => pg-9.1.1/pgis-2.0.0SVN
#
#---------------------------------------------------------------------

use warnings;
use strict;

my $me = $0;

my $usage = qq{
Usage:	$me [-v] <dumpfile>
        Restore a custom dump (pg_dump -Fc) of a PostGIS-enabled database.
        First dump the old database: pg_dump -Fc MYDB > MYDB.dmp
        Then create a new database: createdb NEWDB
        Then install PostGIS in the new database:
           psql -f postgis/postgis.sql NEWDB
        Also install PostGIS topology and raster, if you were using them:
           psql -f topology/topology.sql NEWDB
           psql -f raster/rtpostgis.sql NEWDB
        Finally, pass the dump to this script and feed output to psql:
           $me MYDB.dmp | psql NEWDB
        The -v switch writes detailed report on stderr.

};

my $DEBUG = 0;

if ( @ARGV && $ARGV[0] eq '-v' ) {
  $DEBUG = 1;
  shift(@ARGV);
}

die $usage if (@ARGV < 1);

my $dumpfile = $ARGV[0];
my $manifest = $dumpfile . ".lst";
my $hasTopology = 0;

die "$me:\tUnable to find 'pg_dump' on the path.\n" if ! `pg_dump --version`;
die "$me:\tUnable to find 'pg_restore' on the path.\n" if ! `pg_restore --version`;
die "$me:\tUnable to open dump file '$dumpfile'.\n" if ! -f $dumpfile;

print STDERR "Converting $dumpfile to ASCII on stdout...\n";

######################################################################
# Load the signatures of things to skip.
#

print STDERR "  Reading list of functions to ignore...\n";

my %skip = ();
while(my $l = <DATA>) {
  $l =~ s/\s//g;
  print STDERR "DATA $l\n" if $DEBUG;
  $skip{$l} = 1;
}

######################################################################
# Write a new manifest for the dump file, skipping the things that
# are part of PostGIS
#

print STDERR "  Writing manifest of things to read from dump file...\n";

open( DUMP, "pg_restore -l $dumpfile |" ) || die "$me:\tCannot open dump file '$dumpfile'\n";
open( MANIFEST, ">$manifest" ) || die "$me:\tCannot open manifest file '$manifest'\n";
while( my $l = <DUMP> ) {

  next if $l =~ /^\;/;
  my $sig = linesignature($l);
  $hasTopology = 1 if $sig eq 'SCHEMAtopology';
  if ( $skip{$sig} ) {
    print STDERR "SKIP $sig\n" if $DEBUG;
    next
  }
  print STDERR "KEEP $sig\n" if $DEBUG;
  print MANIFEST $l;

}
close(MANIFEST);
close(DUMP);

######################################################################
# Convert the dump file into an ASCII file, stripping out the 
# unwanted bits.
#
print STDERR "  Writing ASCII to stdout...\n";
open( INPUT, "pg_restore -L $manifest $dumpfile |") || die "$me:\tCan't run pg_restore\n";

#
# Disable topology metadata tables triggers to allow for population
# in arbitrary order.
#
if ( $hasTopology ) {
  print STDOUT "ALTER TABLE topology.layer DISABLE TRIGGER ALL;\n";
}

# Drop the spatial_ref_sys_srid_check to allow for custom invalid SRIDs in the dump
print STDOUT "ALTER TABLE spatial_ref_sys DROP constraint "
           . "spatial_ref_sys_srid_check;\n";

# Backup entries found in new spatial_ref_sys for later updating the
print STDOUT "CREATE TEMP TABLE _pgis_restore_spatial_ref_sys AS "
            ."SELECT * FROM spatial_ref_sys;\n";
print STDOUT "DELETE FROM spatial_ref_sys;\n";

while( my $l = <INPUT> ) {

  next if $l =~ /^ *--/;

  if ( $l =~ /^SET search_path/ ) {
    $l =~ s/; *$/, public;/; 
  }

  # This is to avoid confusing OPERATOR CLASS 
  # with OPERATOR below
  elsif ( $l =~ /CREATE OPERATOR CLASS/)
  {
  }

  # We can't skip OPERATORS from the manifest file
  # because it doesn't contain enough informations
  # about the type the operator is for
  elsif ( $l =~ /CREATE OPERATOR *([^ ,]*)/)
  {
    my $name = canonicalize_typename($1);
    my $larg = undef;
    my $rarg = undef;
    my @sublines = ($l);
    while( my $subline = <INPUT>)
    {
      push(@sublines, $subline);
      last if $subline =~ /;[\t ]*$/;
      if ( $subline =~ /leftarg *= *([^ ,]*)/i )
      {
        $larg=canonicalize_typename($1);
      }
      if ( $subline =~ /rightarg *= *([^ ,]*)/i )
      {
        $rarg=canonicalize_typename($1);
      }
    }

    if ( ! $larg ) {
      print STDERR "No larg, @sublines: [" . @sublines . "]\n";
    }

    my $sig = "OPERATOR" . $name .'('.$larg.','.$rarg.')';

    if ( $skip{$sig} )
    {
       print STDERR "SKIP $sig\n" if $DEBUG;
       next;
    }

    print STDERR "KEEP $sig\n" if $DEBUG;
    print STDOUT @sublines;
    next;
  }

  # Rewrite spatial table constraints
  #
  # Example:
  # CREATE TABLE geos_in (
  #     id integer NOT NULL,
  #     g public.geometry,
  #     CONSTRAINT enforce_dims_g CHECK ((public.st_ndims(g) = 2)),
  #     CONSTRAINT enforce_geotype_g CHECK (((public.geometrytype(g) = 'MULTILINESTRING'::text) OR (g IS NULL))),
  #     CONSTRAINT enforce_srid_g CHECK ((public.st_srid(g) = (-1)))
  # );
  # 
  elsif ( $l =~ /CREATE TABLE *([^ ,]*)/)
  {
    my @sublines = ($l);
    while( my $subline = <INPUT>)
    {
      if ( $subline =~ /CONSTRAINT enforce_dims_/i ) {
        $subline =~ s/\.ndims\(/.st_ndims(/;
      }
      if ( $subline =~ /CONSTRAINT enforce_srid_/i ) {
        $subline =~ s/\.srid\(/.st_srid(/;
        $subline =~ s/\(-1\)/(0)/;
      }
      push(@sublines, $subline);
      last if $subline =~ /;[\t ]*$/;
    }
    print STDOUT @sublines;
    next;
  }

  print STDOUT $l;

}

if ( $hasTopology ) {

  # Re-enable topology.layer table triggers 
  print STDOUT "ALTER TABLE topology.layer ENABLE TRIGGER ALL;\n";

  # Update topology SRID from geometry_columns view.
  # This is mainly to fix srids of -1
  # May be worth providing a "populate_topology_topology"
  print STDOUT "UPDATE topology.topology t set srid = g.srid "
             . "FROM geometry_columns g WHERE t.name = g.f_table_schema "
             . "AND g.f_table_name = 'face' and f_geometry_column = 'mbr';\n";

}

# Update spatial_ref_sys with entries found in new table
print STDOUT "UPDATE spatial_ref_sys o set auth_name = n.auth_name, "
           . "auth_srid = n.auth_srid, srtext = n.srtext, "
           . "proj4text = n.proj4text FROM "
           . "_pgis_restore_spatial_ref_sys n WHERE o.srid = n.srid;\n";
# Insert entries only found in new table
print STDOUT "INSERT INTO spatial_ref_sys SELECT * FROM "
           . "_pgis_restore_spatial_ref_sys n WHERE n.srid " 
           . "NOT IN ( SELECT srid FROM spatial_ref_sys );\n";
# DROP TABLE _pgis_restore_spatial_ref_sys;
print STDOUT "DROP TABLE _pgis_restore_spatial_ref_sys;\n";

# Try re-enforcing spatial_ref_sys_srid_check, would fail if impossible
# but you'd still have your data
print STDOUT "ALTER TABLE spatial_ref_sys ADD constraint " 
           . "spatial_ref_sys_srid_check check "
           . "( srid > 0 and srid < 999000 ) ;\n";


print STDERR "Done.\n";

######################################################################
# Strip a dump file manifest line down to the unique elements of
# type and signature.
#
sub linesignature {

  my $line = shift;
  my $sig;

  $line =~ s/\n$//;
  $line =~ s/\r$//;
  $line =~ s/OPERATOR CLASS/OPERATORCLASS/;
  $line =~ s/TABLE DATA/TABLEDATA/;
  $line =~ s/SHELL TYPE/SHELLTYPE/;
  $line =~ s/PROCEDURAL LANGUAGE/PROCEDURALLANGUAGE/;

  if( $line =~ /^(\d+)\; (\d+) (\d+) FK (\w+) (\w+) (.*) (\w*)/ ) {
    $sig = "FK" . $4 . "\t" . $6;
  }
  elsif( $line =~ /^(\d+)\; (\d+) (\d+) (\w+) (\w+) (.*) (\w*)/ ) {
    $sig = $4 . "\t" . $6;
  }
  elsif( $line =~ /PROCEDURALLANGUAGE.*plpgsql/ ) {
    $sig = "PROCEDURALLANGUAGE\tplpgsql";
  }
  elsif ( $line =~ /SCHEMA - (\w+)/ ) {
    $sig = "SCHEMA\t$1";
  }
  elsif ( $line =~ /SEQUENCE - (\w+)/ ) {
    $sig = "SEQUENCE\t$1";
  }
  else {
    # TODO: something smarter here...
    $sig = $line
  }

  $sig =~ s/\s//g;
  return $sig;

}

#
# Canonicalize type names (they change between dump versions).
# Here we also strip schema qualification
#
sub
canonicalize_typename
{
	my $arg=shift;

	# Lower case
	$arg = lc($arg);

	# Trim whitespaces
	$arg =~ s/^\s*//;
	$arg =~ s/\s*$//;

	# Strip schema qualification
	#$arg =~ s/^public.//;
	$arg =~ s/^.*\.//;

	# Handle type name changes
	if ( $arg eq 'opaque' ) {
		$arg = 'internal';
	} elsif ( $arg eq 'boolean' ) {
		$arg = 'bool';
	} elsif ( $arg eq 'oldgeometry' ) {
		$arg = 'geometry';
	}

	# Timestamp with or without time zone
	if ( $arg =~ /timestamp .* time zone/ ) {
		$arg = 'timestamp';
	}

	return $arg;
}


######################################################################
# Here are all the signatures we want to skip.
#
__END__
AGGREGATE	accum(geometry)
AGGREGATE	accum_old(geometry)
AGGREGATE	collect(geometry)
AGGREGATE	extent3d(geometry)
AGGREGATE	extent(geometry)
AGGREGATE	geomunion(geometry)
AGGREGATE	geomunion_old(geometry)
AGGREGATE	makeline(geometry)
AGGREGATE	memcollect(geometry)
AGGREGATE	memgeomunion(geometry)
AGGREGATE	polygonize(geometry)
AGGREGATE	st_3dextent(geometry)
AGGREGATE	st_accum(geometry)
AGGREGATE	st_accum_old(geometry)
AGGREGATE	st_collect(geometry)
AGGREGATE	st_extent3d(geometry)
AGGREGATE	st_extent(geometry)
AGGREGATE	st_makeline(geometry)
AGGREGATE	st_memcollect(geometry)
AGGREGATE	st_memunion(geometry)
AGGREGATE	st_polygonize(geometry)
AGGREGATE	st_union(geometry)
AGGREGATE	st_union_old(geometry)
AGGREGATE	st_union(raster)
AGGREGATE	st_union(raster,integer)
AGGREGATE	st_union(raster,integer,text)
AGGREGATE	st_union(raster, text)
AGGREGATE	st_union(raster, text, text)
AGGREGATE	st_union(raster, text, text, text)
AGGREGATE	st_union(raster, text, text, text, double precision)
AGGREGATE	st_union(raster, text, text, text, double precision, text, text, text, double precision)
AGGREGATE	st_union(raster, text, text, text, double precision, text, text, text, double precision, text, text, text, double precision)
AGGREGATE	topoelementarray_agg(topoelement)
CAST	CAST (boolean AS text)
CAST	CAST (bytea AS public.geography)
CAST	CAST (bytea AS public.geometry)
CAST	CAST (public.box2d AS public.box3d)
CAST	CAST (public.box2d AS public.geometry)
CAST	CAST (public.box3d AS box)
CAST	CAST (public.box3d AS public.box2d)
CAST	CAST (public.box3d AS public.geometry)
CAST	CAST (public.box3d_extent AS public.box2d)
CAST	CAST (public.box3d_extent AS public.box3d)
CAST	CAST (public.box3d_extent AS public.geometry)
CAST	CAST (public.chip AS public.geometry)
CAST	CAST (public.geography AS bytea)
CAST	CAST (public.geography AS public.geography)
CAST	CAST (public.geography AS public.geometry)
CAST	CAST (public.geometry AS box)
CAST	CAST (public.geometry AS bytea)
CAST	CAST (public.geometry AS public.box2d)
CAST	CAST (public.geometry AS public.box3d)
CAST	CAST (public.geometry AS public.geography)
CAST	CAST (public.geometry AS public.geometry)
CAST	CAST (public.geometry AS text)
CAST	CAST (public.raster AS box2d)
CAST	CAST (public.raster AS bytea)
CAST	CAST (public.raster AS public.box2d)
CAST	CAST (public.rasterASpublic.box3d)
CAST	CAST (public.raster AS public.geometry)
CAST	CAST (raster AS bytea)
CAST	CAST (raster AS geometry)
CAST	CAST (text AS public.geometry)
CAST	CAST (topology.topogeometry AS geometry)
CAST	CAST (topology.topogeometry AS public.geometry)
CONSTRAINT	geometry_columns_pk
CONSTRAINT	layer_pkey
CONSTRAINT	layer_schema_name_key
CONSTRAINT	raster_columns_pk
CONSTRAINT	raster_overviews_pk
CONSTRAINT	spatial_ref_sys_pkey
CONSTRAINT	topology_name_key
CONSTRAINT	topology_pkey
DOMAIN	topoelement
DOMAIN	topoelementarray
DOMAIN	topogeomelementarray
FKCONSTRAINT layer_topology_id_fkey
FUNCION st_addband(raster,integer,text)
FUNCION st_addband(raster,integer,text,doubleprecision)
FUNCION st_addband(raster,raster)
FUNCION st_addband(raster,raster,integer)
FUNCION st_addband(raster,text)
FUNCION st_addband(raster,text,doubleprecision)
FUNCION st_bandisnodata(raster)
FUNCION st_bandisnodata(raster,integer)
FUNCION st_bandmetadata(raster)
FUNCION st_bandnodatavalue(raster)
FUNCION st_bandpath(raster)
FUNCION st_bandpixeltype(raster)
FUNCION st_dumpaspolygons(raster)
FUNCION st_georeference(raster)
FUNCION st_hasnoband(raster)
FUNCION st_makeemptyraster(integer,integer,doubleprecision,doubleprecision,doubleprecision,doubleprecision,doubleprecision,doubleprecision)
FUNCION st_mapalgebraexpr(raster,integer,text,text,text)
FUNCION st_mapalgebraexpr(raster,text,text,text)
FUNCION st_mapalgebra(raster,integer,text)
FUNCION st_mapalgebra(raster,integer,text,text)
FUNCION st_mapalgebra(raster,text)
FUNCION st_mapalgebra(raster,text,text)
FUNCION st_mapalgebra(raster,text,text,text)
FUNCION st_polygon(raster)
FUNCION st_resample(raster,raster,text,doubleprecision)
FUNCION st_setbandisnodata(raster)
FUNCION st_setbandnodatavalue(raster,integer,doubleprecision)
FUNCION st_setgeoreference(raster,text)
FUNCION st_value(raster,integer,integer)
FUNCION st_value(raster,integer,integer,integer)
FUNCTION	addauth(text)
FUNCTION	addbbox(geometry)
FUNCTION	addedge(character varying, public.geometry)
FUNCTION	addface(character varying, public.geometry, boolean)
FUNCTION	addgeometrycolumn(character varying, character varying, character varying, character varying, integer, character varying, integer)
FUNCTION	addgeometrycolumn(character varying, character varying, character varying, character varying, integer, character varying, integer, boolean)
FUNCTION	addgeometrycolumn(character varying, character varying, character varying, integer, character varying, integer)
FUNCTION	addgeometrycolumn(character varying, character varying, character varying, integer, character varying, integer, boolean)
FUNCTION	addgeometrycolumn(character varying, character varying, integer, character varying, integer)
FUNCTION	addgeometrycolumn(character varying, character varying, integer, character varying, integer, boolean)
FUNCTION	addnode(character varying, public.geometry)
FUNCTION	_add_overview_constraint(name, name, name, name, name, name, integer)
FUNCTION	addoverviewconstraints(name, name, name, name, integer)
FUNCTION	addoverviewconstraints(name, name, name, name, name, name, integer)
FUNCTION	addpoint(geometry, geometry)
FUNCTION	addpoint(geometry, geometry, integer)
FUNCTION	addrastercolumn(character varying, character varying, character varying, character varying, integer, character varying[], boolean, boolean, double precision[], double precision, double precision, integer, integer, geometry)
FUNCTION	addrastercolumn(character varying, character varying, character varying, integer, character varying[], boolean, boolean, double precision[], double precision, double precision, integer, integer, geometry)
FUNCTION	addrastercolumn(character varying, character varying, integer, character varying[], boolean, boolean, double precision[], double precision, double precision, integer, integer, geometry)
FUNCTION	_add_raster_constraint_alignment(name, name, name)
FUNCTION	_add_raster_constraint_blocksize(name, name, name, text)
FUNCTION	_add_raster_constraint_extent(name, name, name)
FUNCTION	_add_raster_constraint(name, text)
FUNCTION	_add_raster_constraint_nodata_values(name, name, name)
FUNCTION	_add_raster_constraint_num_bands(name, name, name)
FUNCTION	_add_raster_constraint_pixel_types(name, name, name)
FUNCTION	_add_raster_constraint_regular_blocking(name, name, name)
FUNCTION	_add_raster_constraint_scale(name, name, name, character)
FUNCTION	addrasterconstraints(name, name, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean)
FUNCTION	addrasterconstraints(name, name, name, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean)
FUNCTION	addrasterconstraints(name, name, name, text[])
FUNCTION	addrasterconstraints(name, name, text[])
FUNCTION	_add_raster_constraint_srid(name, name, name)
FUNCTION	addtopogeometrycolumn(character varying, character varying, character varying, character varying, character varying)
FUNCTION	addtopogeometrycolumn(character varying, character varying, character varying, character varying, character varying, integer)
FUNCTION	addtosearchpath(character varying)
FUNCTION	affine(geometry, double precision, double precision, double precision, double precision, double precision, double precision)
FUNCTION	affine(geometry, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision)
FUNCTION	area2d(geometry)
FUNCTION	area(geometry)
FUNCTION	asbinary(geometry)
FUNCTION	asbinary(geometry, text)
FUNCTION	asewkb(geometry)
FUNCTION	asewkb(geometry, text)
FUNCTION	asewkt(geometry)
FUNCTION	_asgmledge(integer,integer,integer,public.geometry,regclass,text,integer,integer)
FUNCTION	_asgmledge(integer,integer,integer,public.geometry,regclass,text,integer,integer,text)
FUNCTION	_asgmledge(integer, integer, integer, public.geometry, regclass, text, integer, integer, text, integer)
FUNCTION	_asgmledge(integer,integer,integer,public.geometry,text)
FUNCTION	asgmledge(integer,integer,integer,public.geometry,text)
FUNCTION	_asgmledge(integer,integer,integer,public.geometry,text,integer,integer)
FUNCTION	_asgmlface(text, integer, regclass, text, integer, integer, text, integer)
FUNCTION	asgml(geometry)
FUNCTION	asgml(geometry, integer)
FUNCTION	asgml(geometry, integer, integer)
FUNCTION	_asgmlnode(integer,public.geometry,text)
FUNCTION	asgmlnode(integer,public.geometry,text)
FUNCTION	_asgmlnode(integer,public.geometry,text,integer,integer)
FUNCTION	_asgmlnode(integer,public.geometry,text,integer,integer,text)
FUNCTION	_asgmlnode(integer, public.geometry, text, integer, integer, text, integer)
FUNCTION	asgml(topogeometry)
FUNCTION	asgml(topogeometry, regclass)
FUNCTION	asgml(topogeometry, regclass, text)
FUNCTION	asgml(topogeometry, text)
FUNCTION	asgml(topogeometry, text, integer, integer)
FUNCTION	asgml(topogeometry, text, integer, integer, regclass)
FUNCTION	asgml(topogeometry, text, integer, integer, regclass, text)
FUNCTION	asgml(topogeometry, text, integer, integer, regclass, text, integer)
FUNCTION	ashexewkb(geometry)
FUNCTION	ashexewkb(geometry, text)
FUNCTION	askml(geometry)
FUNCTION	askml(geometry, integer)
FUNCTION	askml(geometry, integer, integer)
FUNCTION	askml(integer, geometry, integer)
FUNCTION	assvg(geometry)
FUNCTION	assvg(geometry, integer)
FUNCTION	assvg(geometry, integer, integer)
FUNCTION	astext(geometry)
FUNCTION	asukml(geometry)
FUNCTION	asukml(geometry, integer)
FUNCTION	asukml(geometry, integer, integer)
FUNCTION	azimuth(geometry, geometry)
FUNCTION	bdmpolyfromtext(text, integer)
FUNCTION	bdpolyfromtext(text, integer)
FUNCTION	boundary(geometry)
FUNCTION	box2d(box3d)
FUNCTION	box2d(box3d_extent)
FUNCTION	box2d_contain(box2d, box2d)
FUNCTION	box2d_contained(box2d, box2d)
FUNCTION	box2df_in(cstring)
FUNCTION	box2df_out(box2df)
FUNCTION	box2d(geometry)
FUNCTION	box2d_in(cstring)
FUNCTION	box2d_intersects(box2d, box2d)
FUNCTION	box2d_left(box2d, box2d)
FUNCTION	box2d_out(box2d)
FUNCTION	box2d_overlap(box2d, box2d)
FUNCTION	box2d_overleft(box2d, box2d)
FUNCTION	box2d_overright(box2d, box2d)
FUNCTION	box2d(raster)
FUNCTION	box2d_right(box2d, box2d)
FUNCTION	box2d_same(box2d, box2d)
FUNCTION	box3d(box2d)
FUNCTION	box3d_extent(box3d_extent)
FUNCTION	box3d_extent_in(cstring)
FUNCTION	box3d_extent_out(box3d_extent)
FUNCTION	box3d(geometry)
FUNCTION	box3d_in(cstring)
FUNCTION	box3d_out(box3d)
FUNCTION	box3d(raster)
FUNCTION	box3dtobox(box3d)
FUNCTION	box(box3d)
FUNCTION	box(geometry)
FUNCTION	buffer(geometry, double precision)
FUNCTION	buffer(geometry, double precision, integer)
FUNCTION	buildarea(geometry)
FUNCTION	build_histogram2d(histogram2d, text, text)
FUNCTION	build_histogram2d(histogram2d, text, text, text)
FUNCTION	bytea(geography)
FUNCTION	bytea(geometry)
FUNCTION	bytea(raster)
FUNCTION	cache_bbox()
FUNCTION	centroid(geometry)
FUNCTION	checkauth(text, text)
FUNCTION	checkauth(text, text, text)
FUNCTION	checkauthtrigger()
FUNCTION	chip_in(cstring)
FUNCTION	chip_out(chip)
FUNCTION	collect_garray(geometry[])
FUNCTION	collect(geometry, geometry)
FUNCTION	collector(geometry, geometry)
FUNCTION	combine_bbox(box2d, geometry)
FUNCTION	combine_bbox(box3d_extent, geometry)
FUNCTION	combine_bbox(box3d, geometry)
FUNCTION	compression(chip)
FUNCTION	contains(geometry, geometry)
FUNCTION	convexhull(geometry)
FUNCTION	copytopology(character varying, character varying)
FUNCTION	create_histogram2d(box2d, integer)
FUNCTION	createtopogeom(character varying, integer, integer, topoelementarray)
FUNCTION	createtopology(character varying)
FUNCTION	createtopology(character varying, integer)
FUNCTION	createtopology(character varying, integer, double precision)
FUNCTION	createtopology(character varying, integer, double precision, boolean)
FUNCTION	crosses(geometry, geometry)
FUNCTION	datatype(chip)
FUNCTION	difference(geometry, geometry)
FUNCTION	dimension(geometry)
FUNCTION	disablelongtransactions()
FUNCTION	disjoint(geometry, geometry)
FUNCTION	distance(geometry, geometry)
FUNCTION	distance_sphere(geometry, geometry)
FUNCTION	distance_spheroid(geometry, geometry, spheroid)
FUNCTION	dropbbox(geometry)
FUNCTION	dropgeometrycolumn(character varying, character varying)
FUNCTION	dropgeometrycolumn(character varying, character varying, character varying)
FUNCTION	dropgeometrycolumn(character varying, character varying, character varying, character varying)
FUNCTION	dropgeometrytable(character varying)
FUNCTION	dropgeometrytable(character varying, character varying)
FUNCTION	dropgeometrytable(character varying, character varying, character varying)
FUNCTION	_drop_overview_constraint(name, name, name)
FUNCTION	dropoverviewconstraints(name, name)
FUNCTION	dropoverviewconstraints(name, name, name)
FUNCTION	droprastercolumn(character varying, character varying)
FUNCTION	droprastercolumn(character varying, character varying, character varying)
FUNCTION	droprastercolumn(character varying, character varying, character varying, character varying)
FUNCTION	_drop_raster_constraint_alignment(name, name, name)
FUNCTION	_drop_raster_constraint_blocksize(name, name, name, text)
FUNCTION	_drop_raster_constraint_extent(name, name, name)
FUNCTION	_drop_raster_constraint(name, name, name)
FUNCTION	_drop_raster_constraint_nodata_values(name, name, name)
FUNCTION	_drop_raster_constraint_num_bands(name, name, name)
FUNCTION	_drop_raster_constraint_pixel_types(name, name, name)
FUNCTION	_drop_raster_constraint_regular_blocking(name, name, name)
FUNCTION	_drop_raster_constraint_scale(name, name, name, character)
FUNCTION	droprasterconstraints(name, name, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean)
FUNCTION	droprasterconstraints(name, name, name, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean)
FUNCTION	droprasterconstraints(name, name, name, text[])
FUNCTION	droprasterconstraints(name, name, text[])
FUNCTION	_drop_raster_constraint_srid(name, name, name)
FUNCTION	droprastertable(character varying)
FUNCTION	droprastertable(character varying, character varying)
FUNCTION	droprastertable(character varying, character varying, character varying)
FUNCTION	droptopogeometrycolumn(character varying, character varying, character varying)
FUNCTION	droptopology(character varying)
FUNCTION	dumpaswktpolygons(raster, integer)
FUNCTION	dump(geometry)
FUNCTION	dumprings(geometry)
FUNCTION	enablelongtransactions()
FUNCTION	endpoint(geometry)
FUNCTION	envelope(geometry)
FUNCTION	envelope(topogeometry)
FUNCTION	equals(geometry, geometry)
FUNCTION	equals(topogeometry, topogeometry)
FUNCTION	estimated_extent(text, text)
FUNCTION	estimated_extent(text, text, text)
FUNCTION	estimate_histogram2d(histogram2d, box2d)
FUNCTION	expand(box2d, double precision)
FUNCTION	expand(box3d, double precision)
FUNCTION	expand(geometry, double precision)
FUNCTION	explode_histogram2d(histogram2d, text)
FUNCTION	exteriorring(geometry)
FUNCTION	factor(chip)
FUNCTION	find_extent(text, text)
FUNCTION	find_extent(text, text, text)
FUNCTION	find_srid(character varying, character varying, character varying)
FUNCTION	fix_geometry_columns()
FUNCTION	force_2d(geometry)
FUNCTION	force_3d(geometry)
FUNCTION	force_3dm(geometry)
FUNCTION	force_3dz(geometry)
FUNCTION	force_4d(geometry)
FUNCTION	force_collection(geometry)
FUNCTION	forcerhr(geometry)
FUNCTION	geography_analyze(internal)
FUNCTION	geography(bytea)
FUNCTION	geography_cmp(geography, geography)
FUNCTION	geography_eq(geography, geography)
FUNCTION	geography_ge(geography, geography)
FUNCTION	geography(geography, integer, boolean)
FUNCTION	geography(geometry)
FUNCTION	geography_gist_compress(internal)
FUNCTION	geography_gist_consistent(internal, geography, integer)
FUNCTION	geography_gist_decompress(internal)
FUNCTION	geography_gist_join_selectivity(internal, oid, internal, smallint)
FUNCTION	geography_gist_penalty(internal, internal, internal)
FUNCTION	geography_gist_picksplit(internal, internal)
FUNCTION	geography_gist_same(box2d, box2d, internal)
FUNCTION	geography_gist_selectivity(internal, oid, internal, integer)
FUNCTION	geography_gist_union(bytea, internal)
FUNCTION	geography_gt(geography, geography)
FUNCTION	geography_in(cstring, oid, integer)
FUNCTION	geography_le(geography, geography)
FUNCTION	geography_lt(geography, geography)
FUNCTION	geography_out(geography)
FUNCTION	geography_overlaps(geography, geography)
FUNCTION	geography_typmod_in(cstring[])
FUNCTION	geography_typmod_out(integer)
FUNCTION	geom_accum(geometry[], geometry)
FUNCTION	geomcollfromtext(text)
FUNCTION	geomcollfromtext(text, integer)
FUNCTION	geomcollfromwkb(bytea)
FUNCTION	geomcollfromwkb(bytea, integer)
FUNCTION	geometry_above(geometry, geometry)
FUNCTION	geometry_analyze(internal)
FUNCTION	geometry_below(geometry, geometry)
FUNCTION	geometry(box2d)
FUNCTION	geometry(box3d)
FUNCTION	geometry(box3d_extent)
FUNCTION	geometry(bytea)
FUNCTION	geometry(chip)
FUNCTION	geometry_cmp(geometry, geometry)
FUNCTION	geometry_contained(geometry, geometry)
FUNCTION	geometry_contain(geometry, geometry)
FUNCTION	geometry_contains(geometry, geometry)
FUNCTION	geometry_distance_box(geometry, geometry)
FUNCTION	geometry_distance_centroid(geometry, geometry)
FUNCTION	geometry_eq(geometry, geometry)
FUNCTION	geometryfromtext(text)
FUNCTION	geometryfromtext(text, integer)
FUNCTION	geometry_ge(geometry, geometry)
FUNCTION	geometry(geography)
FUNCTION	geometry(geometry, integer, boolean)
FUNCTION	geometry_gist_compress_2d(internal)
FUNCTION	geometry_gist_compress_nd(internal)
FUNCTION	geometry_gist_consistent_2d(internal, geometry, integer)
FUNCTION	geometry_gist_consistent_nd(internal, geometry, integer)
FUNCTION	geometry_gist_decompress_2d(internal)
FUNCTION	geometry_gist_decompress_nd(internal)
FUNCTION	geometry_gist_distance_2d(internal, geometry, integer)
FUNCTION	geometry_gist_joinsel_2d(internal, oid, internal, smallint)
FUNCTION	geometry_gist_penalty_2d(internal, internal, internal)
FUNCTION	geometry_gist_penalty_nd(internal, internal, internal)
FUNCTION	geometry_gist_picksplit_2d(internal, internal)
FUNCTION	geometry_gist_picksplit_nd(internal, internal)
FUNCTION	geometry_gist_same_2d(geometry, geometry, internal)
FUNCTION	geometry_gist_same_nd(geometry, geometry, internal)
FUNCTION	geometry_gist_sel_2d(internal, oid, internal, integer)
FUNCTION	geometry_gist_union_2d(bytea, internal)
FUNCTION	geometry_gist_union_nd(bytea, internal)
FUNCTION	geometry_gt(geometry, geometry)
FUNCTION	geometry_in(cstring)
FUNCTION	geometry_left(geometry, geometry)
FUNCTION	geometry_le(geometry, geometry)
FUNCTION	geometry_lt(geometry, geometry)
FUNCTION	geometryn(geometry, integer)
FUNCTION	geometry_out(geometry)
FUNCTION	geometry_overabove(geometry, geometry)
FUNCTION	geometry_overbelow(geometry, geometry)
FUNCTION	geometry_overlap(geometry, geometry)
FUNCTION	geometry_overlaps(geometry, geometry)
FUNCTION	geometry_overlaps_nd(geometry, geometry)
FUNCTION	geometry_overleft(geometry, geometry)
FUNCTION	geometry_overright(geometry, geometry)
FUNCTION	geometry_recv(internal)
FUNCTION	geometry_right(geometry, geometry)
FUNCTION	geometry_samebox(geometry, geometry)
FUNCTION	geometry_same(geometry, geometry)
FUNCTION	geometry_send(geometry)
FUNCTION	geometry(text)
FUNCTION	geometry(topogeometry)
FUNCTION	geometrytype(geometry)
FUNCTION	geometrytype(topogeometry)
FUNCTION	geometry_typmod_in(cstring[])
FUNCTION	geometry_typmod_out(integer)
FUNCTION	geometry_within(geometry, geometry)
FUNCTION	geomfromewkb(bytea)
FUNCTION	geomfromewkt(text)
FUNCTION	geomfromtext(text)
FUNCTION	geomfromtext(text, integer)
FUNCTION	geomfromwkb(bytea)
FUNCTION	geomfromwkb(bytea, integer)
FUNCTION	geomunion(geometry, geometry)
FUNCTION	geosnoop(geometry)
FUNCTION	getbbox(geometry)
FUNCTION	getedgebypoint(character varying, public.geometry, double precision)
FUNCTION	getfacebypoint(character varying, public.geometry, double precision)
FUNCTION	getnodebypoint(character varying, public.geometry, double precision)
FUNCTION	get_proj4_from_srid(integer)
FUNCTION	getringedges(character varying, integer, integer)
FUNCTION	getsrid(geometry)
FUNCTION	gettopogeomelementarray(character varying, integer, integer)
FUNCTION	gettopogeomelementarray(topogeometry)
FUNCTION	gettopogeomelements(character varying, integer, integer)
FUNCTION	gettopogeomelements(topogeometry)
FUNCTION	gettopologyid(character varying)
FUNCTION	gettopologyname(integer)
FUNCTION	gettransactionid()
FUNCTION	gidx_in(cstring)
FUNCTION	gidx_out(gidx)
FUNCTION	hasbbox(geometry)
FUNCTION	height(chip)
FUNCTION	histogram2d_in(cstring)
FUNCTION	histogram2d_out(histogram2d)
FUNCTION	interiorringn(geometry, integer)
FUNCTION	intersection(geometry, geometry)
FUNCTION	intersects(geometry, geometry)
FUNCTION	intersects(topogeometry, topogeometry)
FUNCTION	isclosed(geometry)
FUNCTION	isempty(geometry)
FUNCTION	isring(geometry)
FUNCTION	issimple(geometry)
FUNCTION	isvalid(geometry)
FUNCTION	jtsnoop(geometry)
FUNCTION	layertrigger()
FUNCTION	length2d(geometry)
FUNCTION	length2d_spheroid(geometry, spheroid)
FUNCTION	length3d(geometry)
FUNCTION	length3d_spheroid(geometry, spheroid)
FUNCTION	length(geometry)
FUNCTION	length_spheroid(geometry, spheroid)
FUNCTION	linefrommultipoint(geometry)
FUNCTION	linefromtext(text)
FUNCTION	linefromtext(text, integer)
FUNCTION	linefromwkb(bytea)
FUNCTION	linefromwkb(bytea, integer)
FUNCTION	line_interpolate_point(geometry, double precision)
FUNCTION	line_locate_point(geometry, geometry)
FUNCTION	linemerge(geometry)
FUNCTION	linestringfromtext(text)
FUNCTION	linestringfromtext(text, integer)
FUNCTION	linestringfromwkb(bytea)
FUNCTION	linestringfromwkb(bytea, integer)
FUNCTION	line_substring(geometry, double precision, double precision)
FUNCTION	locate_along_measure(geometry, double precision)
FUNCTION	locate_between_measures(geometry, double precision, double precision)
FUNCTION	lockrow(text, text, text)
FUNCTION	lockrow(text, text, text, text)
FUNCTION	lockrow(text, text, text, text, timestamp without time zone)
FUNCTION	lockrow(text, text, text, timestamp without time zone)
FUNCTION	longtransactionsenabled()
FUNCTION	lwgeom_gist_compress(internal)
FUNCTION	lwgeom_gist_consistent(internal, geometry, integer)
FUNCTION	lwgeom_gist_decompress(internal)
FUNCTION	lwgeom_gist_penalty(internal, internal, internal)
FUNCTION	lwgeom_gist_picksplit(internal, internal)
FUNCTION	lwgeom_gist_same(box2d, box2d, internal)
FUNCTION	lwgeom_gist_union(bytea, internal)
FUNCTION	makebox2d(geometry, geometry)
FUNCTION	makebox3d(geometry, geometry)
FUNCTION	makeline_garray(geometry[])
FUNCTION	makeline(geometry, geometry)
FUNCTION	makepoint(double precision, double precision)
FUNCTION	makepoint(double precision, double precision, double precision)
FUNCTION	makepoint(double precision, double precision, double precision, double precision)
FUNCTION	makepointm(double precision, double precision, double precision)
FUNCTION	makepolygon(geometry)
FUNCTION	makepolygon(geometry, geometry[])
FUNCTION	mapalgebra4unionfinal1(rastexpr)
FUNCTION	mapalgebra4unionfinal3(rastexpr)
FUNCTION	mapalgebra4unionstate(raster, raster, text, text, text, double precision, text, text, text, double precision)
FUNCTION	mapalgebra4unionstate(rastexpr, raster)
FUNCTION	mapalgebra4unionstate(rastexpr, raster, text)
FUNCTION	mapalgebra4unionstate(rastexpr, raster, text, text)
FUNCTION	mapalgebra4unionstate(rastexpr, raster, text, text, text)
FUNCTION	mapalgebra4unionstate(rastexpr, raster, text, text, text, double precision)
FUNCTION	mapalgebra4unionstate(rastexpr, raster, text, text, text, double precision, text, text, text, double precision)
FUNCTION	mapalgebra4unionstate(rastexpr, raster, text, text, text, double precision, text, text, text, double precision, text, text, text, double precision)
FUNCTION	max_distance(geometry, geometry)
FUNCTION	mem_size(geometry)
FUNCTION	m(geometry)
FUNCTION	mlinefromtext(text)
FUNCTION	mlinefromtext(text, integer)
FUNCTION	mlinefromwkb(bytea)
FUNCTION	mlinefromwkb(bytea, integer)
FUNCTION	mpointfromtext(text)
FUNCTION	mpointfromtext(text, integer)
FUNCTION	mpointfromwkb(bytea)
FUNCTION	mpointfromwkb(bytea, integer)
FUNCTION	mpolyfromtext(text)
FUNCTION	mpolyfromtext(text, integer)
FUNCTION	mpolyfromwkb(bytea)
FUNCTION	mpolyfromwkb(bytea, integer)
FUNCTION	multi(geometry)
FUNCTION	multilinefromwkb(bytea)
FUNCTION	multilinefromwkb(bytea, integer)
FUNCTION	multilinestringfromtext(text)
FUNCTION	multilinestringfromtext(text, integer)
FUNCTION	multipointfromtext(text)
FUNCTION	multipointfromtext(text, integer)
FUNCTION	multipointfromwkb(bytea)
FUNCTION	multipointfromwkb(bytea, integer)
FUNCTION	multipolyfromwkb(bytea)
FUNCTION	multipolyfromwkb(bytea, integer)
FUNCTION	multipolygonfromtext(text)
FUNCTION	multipolygonfromtext(text, integer)
FUNCTION	ndims(geometry)
FUNCTION	noop(geometry)
FUNCTION	npoints(geometry)
FUNCTION	nrings(geometry)
FUNCTION	numgeometries(geometry)
FUNCTION	numinteriorring(geometry)
FUNCTION	numinteriorrings(geometry)
FUNCTION	numpoints(geometry)
FUNCTION	overlaps(geometry, geometry)
FUNCTION	_overview_constraint_info(name, name, name)
FUNCTION	_overview_constraint(raster, integer, name, name, name)
FUNCTION	perimeter2d(geometry)
FUNCTION	perimeter3d(geometry)
FUNCTION	perimeter(geometry)
FUNCTION	pgis_abs_in(cstring)
FUNCTION	pgis_abs_out(pgis_abs)
FUNCTION	pgis_geometry_accum_finalfn(pgis_abs)
FUNCTION	pgis_geometry_accum_transfn(pgis_abs, geometry)
FUNCTION	pgis_geometry_collect_finalfn(pgis_abs)
FUNCTION	pgis_geometry_makeline_finalfn(pgis_abs)
FUNCTION	pgis_geometry_polygonize_finalfn(pgis_abs)
FUNCTION	pgis_geometry_union_finalfn(pgis_abs)
FUNCTION	pointfromtext(text)
FUNCTION	pointfromtext(text, integer)
FUNCTION	pointfromwkb(bytea)
FUNCTION	pointfromwkb(bytea, integer)
FUNCTION	point_inside_circle(geometry, double precision, double precision, double precision)
FUNCTION	pointn(geometry, integer)
FUNCTION	pointonsurface(geometry)
FUNCTION	polyfromtext(text)
FUNCTION	polyfromtext(text, integer)
FUNCTION	polyfromwkb(bytea)
FUNCTION	polyfromwkb(bytea, integer)
FUNCTION	polygonfromtext(text)
FUNCTION	polygonfromtext(text, integer)
FUNCTION	polygonfromwkb(bytea)
FUNCTION	polygonfromwkb(bytea, integer)
FUNCTION	polygonize(character varying)
FUNCTION	polygonize_garray(geometry[])
FUNCTION	populate_geometry_columns()
FUNCTION	populate_geometry_columns(boolean)
FUNCTION	populate_geometry_columns(oid)
FUNCTION	populate_geometry_columns(oid, boolean)
FUNCTION	postgis_addbbox(geometry)
FUNCTION	postgis_cache_bbox()
FUNCTION	postgis_constraint_dims(text, text, text)
FUNCTION	postgis_constraint_srid(text, text, text)
FUNCTION	postgis_constraint_type(text, text, text)
FUNCTION	postgis_dropbbox(geometry)
FUNCTION	postgis_full_version()
FUNCTION	postgis_gdal_version()
FUNCTION	postgis_geos_version()
FUNCTION	postgis_getbbox(geometry)
FUNCTION	postgis_gist_joinsel(internal, oid, internal, smallint)
FUNCTION	postgis_gist_sel(internal, oid, internal, integer)
FUNCTION	postgis_hasbbox(geometry)
FUNCTION	postgis_jts_version()
FUNCTION	postgis_lib_build_date()
FUNCTION	postgis_lib_version()
FUNCTION	postgis_libxml_version()
FUNCTION	postgis_noop(geometry)
FUNCTION	postgis_proj_version()
FUNCTION	postgis_raster_lib_build_date()
FUNCTION	postgis_raster_lib_version()
FUNCTION	postgis_scripts_build_date()
FUNCTION	postgis_scripts_installed()
FUNCTION	postgis_scripts_released()
FUNCTION	postgis_transform_geometry(geometry, text, text, integer)
FUNCTION	postgis_type_name(character varying, integer, boolean)
FUNCTION	postgis_typmod_dims(integer)
FUNCTION	postgis_typmod_srid(integer)
FUNCTION	postgis_typmod_type(integer)
FUNCTION	postgis_uses_stats()
FUNCTION	postgis_version()
FUNCTION	probe_geometry_columns()
FUNCTION	raster_above(raster,raster)
FUNCTION	raster_below(raster,raster)
FUNCTION	_raster_constraint_info_alignment(name, name, name)
FUNCTION	_raster_constraint_info_blocksize(name, name, name, text)
FUNCTION	_raster_constraint_info_extent(name, name, name)
FUNCTION	_raster_constraint_info_nodata_values(name, name, name)
FUNCTION	_raster_constraint_info_num_bands(name, name, name)
FUNCTION	_raster_constraint_info_pixel_types(name, name, name)
FUNCTION	_raster_constraint_info_regular_blocking(name, name, name)
FUNCTION	_raster_constraint_info_scale(name, name, name, character)
FUNCTION	_raster_constraint_info_srid(name, name, name)
FUNCTION	_raster_constraint_nodata_values(raster)
FUNCTION	_raster_constraint_pixel_types(raster)
FUNCTION	raster_contained(raster,raster)
FUNCTION	raster_contain(raster,raster)
FUNCTION	raster_in(cstring)
FUNCTION	raster_left(raster,raster)
FUNCTION	raster_out(raster)
FUNCTION	raster_overabove(raster,raster)
FUNCTION	raster_overbelow(raster,raster)
FUNCTION	raster_overlap(raster,raster)
FUNCTION	raster_overleft(raster,raster)
FUNCTION	raster_overright(raster,raster)
FUNCTION	raster_right(raster,raster)
FUNCTION	raster_same(raster,raster)
FUNCTION	relate(geometry, geometry)
FUNCTION	relate(geometry, geometry, text)
FUNCTION	relationtrigger()
FUNCTION	removepoint(geometry, integer)
FUNCTION	rename_geometry_table_constraints()
FUNCTION	reverse(geometry)
FUNCTION	rotate(geometry, double precision)
FUNCTION	rotatex(geometry, double precision)
FUNCTION	rotatey(geometry, double precision)
FUNCTION	rotatez(geometry, double precision)
FUNCTION	scale(geometry, double precision, double precision)
FUNCTION	scale(geometry, double precision, double precision, double precision)
FUNCTION	se_envelopesintersect(geometry, geometry)
FUNCTION	segmentize(geometry, double precision)
FUNCTION	se_is3d(geometry)
FUNCTION	se_ismeasured(geometry)
FUNCTION	se_locatealong(geometry, double precision)
FUNCTION	se_locatebetween(geometry, double precision, double precision)
FUNCTION	se_m(geometry)
FUNCTION	setfactor(chip, real)
FUNCTION	setpoint(geometry, integer, geometry)
FUNCTION	setsrid(chip, integer)
FUNCTION	setsrid(geometry, integer)
FUNCTION	se_z(geometry)
FUNCTION	shift_longitude(geometry)
FUNCTION	simplify(geometry, double precision)
FUNCTION	snaptogrid(geometry, double precision)
FUNCTION	snaptogrid(geometry, double precision, double precision)
FUNCTION	snaptogrid(geometry, double precision, double precision, double precision, double precision)
FUNCTION	snaptogrid(geometry, geometry, double precision, double precision, double precision, double precision)
FUNCTION	spheroid_in(cstring)
FUNCTION	spheroid_out(spheroid)
FUNCTION	srid(chip)
FUNCTION	srid(geometry)
FUNCTION	st_3dclosestpoint(geometry, geometry)
FUNCTION	_st_3ddfullywithin(geometry, geometry, double precision)
FUNCTION	st_3ddfullywithin(geometry, geometry, double precision)
FUNCTION	st_3ddistance(geometry, geometry)
FUNCTION	_st_3ddwithin(geometry, geometry, double precision)
FUNCTION	st_3ddwithin(geometry, geometry, double precision)
FUNCTION	st_3dintersects(geometry, geometry)
FUNCTION	st_3dlength(geometry)
FUNCTION	st_3dlength_spheroid(geometry, spheroid)
FUNCTION	st_3dlongestline(geometry, geometry)
FUNCTION	st_3dmakebox(geometry, geometry)
FUNCTION	ST_3DMakeBox(geometry, geometry)
FUNCTION	st_3dmaxdistance(geometry, geometry)
FUNCTION	st_3dperimeter(geometry)
FUNCTION	ST_3DPerimeter(geometry)
FUNCTION	st_3dshortestline(geometry, geometry)
FUNCTION	st_above(raster, raster)
FUNCTION	st_addband(raster,integer,text)
FUNCTION	st_addband(raster,integer,text,doubleprecision)
FUNCTION	st_addband(raster, integer, text, double precision, double precision)
FUNCTION	st_addband(raster,raster)
FUNCTION	st_addband(raster,raster,integer)
FUNCTION	st_addband(raster,raster[],integer)
FUNCTION	st_addband(raster, raster, integer, integer)
FUNCTION	st_addband(raster,text)
FUNCTION	st_addband(raster,text,doubleprecision)
FUNCTION	st_addband(raster, text, double precision, double precision)
FUNCTION	st_addbbox(geometry)
FUNCTION	st_addedgemodface(character varying, integer, integer, public.geometry)
FUNCTION	st_addedgenewfaces(character varying, integer, integer, public.geometry)
FUNCTION	st_addisoedge(character varying, integer, integer, public.geometry)
FUNCTION	st_addisonode(character varying, integer, public.geometry)
FUNCTION	st_addmeasure(geometry, double precision, double precision)
FUNCTION	st_addpoint(geometry, geometry)
FUNCTION	st_addpoint(geometry, geometry, integer)
FUNCTION	st_affine(geometry, double precision, double precision, double precision, double precision, double precision, double precision)
FUNCTION	st_affine(geometry, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision)
FUNCTION	st_approxcount(raster, boolean, double precision)
FUNCTION	st_approxcount(raster, double precision)
FUNCTION	st_approxcount(raster, integer, boolean, double precision)
FUNCTION	st_approxcount(raster, integer, double precision)
FUNCTION	st_approxcount(text, text, boolean, double precision)
FUNCTION	st_approxcount(text, text, double precision)
FUNCTION	st_approxcount(text, text, integer, boolean, double precision)
FUNCTION	st_approxcount(text, text, integer, double precision)
FUNCTION	st_approxhistogram(raster, double precision)
FUNCTION	st_approxhistogram(raster, integer, boolean, double precision, integer, boolean)
FUNCTION	st_approxhistogram(raster, integer, boolean, double precision, integer, double precision[], boolean)
FUNCTION	st_approxhistogram(raster, integer, double precision)
FUNCTION	st_approxhistogram(raster, integer, double precision, integer, boolean)
FUNCTION	st_approxhistogram(raster, integer, double precision, integer, double precision[], boolean)
FUNCTION	st_approxhistogram(text, text, double precision)
FUNCTION	st_approxhistogram(text, text, integer, boolean, double precision, integer, boolean)
FUNCTION	st_approxhistogram(text, text, integer, boolean, double precision, integer, double precision[], boolean)
FUNCTION	st_approxhistogram(text, text, integer, double precision)
FUNCTION	st_approxhistogram(text, text, integer, double precision, integer, boolean)
FUNCTION	st_approxhistogram(text, text, integer, double precision, integer, double precision[], boolean)
FUNCTION	st_approxquantile(raster, boolean, double precision)
FUNCTION	st_approxquantile(raster, double precision)
FUNCTION	st_approxquantile(raster, double precision[])
FUNCTION	st_approxquantile(raster, double precision, double precision)
FUNCTION	st_approxquantile(raster, double precision, double precision[])
FUNCTION	st_approxquantile(raster, integer, boolean, double precision, double precision)
FUNCTION	st_approxquantile(raster, integer, boolean, double precision, double precision[])
FUNCTION	st_approxquantile(raster, integer, double precision, double precision)
FUNCTION	st_approxquantile(raster, integer, double precision, double precision[])
FUNCTION	st_approxquantile(text, text, boolean, double precision)
FUNCTION	st_approxquantile(text, text, double precision)
FUNCTION	st_approxquantile(text, text, double precision[])
FUNCTION	st_approxquantile(text, text, double precision, double precision)
FUNCTION	st_approxquantile(text, text, double precision, double precision[])
FUNCTION	st_approxquantile(text, text, integer, boolean, double precision, double precision)
FUNCTION	st_approxquantile(text, text, integer, boolean, double precision, double precision[])
FUNCTION	st_approxquantile(text, text, integer, double precision, double precision)
FUNCTION	st_approxquantile(text, text, integer, double precision, double precision[])
FUNCTION	st_approxsummarystats(raster, boolean, double precision)
FUNCTION	st_approxsummarystats(raster, double precision)
FUNCTION	st_approxsummarystats(raster, integer, boolean, double precision)
FUNCTION	st_approxsummarystats(raster, integer, double precision)
FUNCTION	st_approxsummarystats(text, text, boolean)
FUNCTION	st_approxsummarystats(text, text, double precision)
FUNCTION	st_approxsummarystats(text, text, integer, boolean, double precision)
FUNCTION	st_approxsummarystats(text, text, integer, double precision)
FUNCTION	st_area2d(geometry)
FUNCTION	st_area(geography, boolean)
FUNCTION	st_area(geometry)
FUNCTION	st_area(text)
FUNCTION	startpoint(geometry)
FUNCTION	st_asbinary(geography)
FUNCTION	st_asbinary(geometry)
FUNCTION	st_asbinary(geometry, text)
FUNCTION	st_asbinary(raster)
FUNCTION	st_asbinary(text)
FUNCTION	st_asewkb(geometry)
FUNCTION	st_asewkb(geometry, text)
FUNCTION	st_asewkt(geometry)
FUNCTION	st_asgdalraster(raster, text, text[], integer)
FUNCTION	st_asgeojson(geography)
FUNCTION	st_asgeojson(geography, integer)
FUNCTION	st_asgeojson(geography, integer, integer)
FUNCTION	st_asgeojson(geometry)
FUNCTION	st_asgeojson(geometry, integer)
FUNCTION	st_asgeojson(geometry, integer, integer)
FUNCTION	st_asgeojson(integer, geography)
FUNCTION	st_asgeojson(integer, geography, integer)
FUNCTION	_st_asgeojson(integer, geography, integer, integer)
FUNCTION	st_asgeojson(integer, geography, integer, integer)
FUNCTION	st_asgeojson(integer, geometry)
FUNCTION	st_asgeojson(integer, geometry, integer)
FUNCTION	_st_asgeojson(integer, geometry, integer, integer)
FUNCTION	st_asgeojson(integer, geometry, integer, integer)
FUNCTION	st_asgeojson(text)
FUNCTION	st_asgml(geography)
FUNCTION	st_asgml(geography, integer)
FUNCTION	st_asgml(geography, integer, integer)
FUNCTION	st_asgml(geometry)
FUNCTION	st_asgml(geometry, integer)
FUNCTION	st_asgml(geometry, integer, integer)
FUNCTION	st_asgml(integer, geography)
FUNCTION	st_asgml(integer, geography, integer)
FUNCTION	st_asgml(integer, geography, integer, integer)
FUNCTION	_st_asgml(integer, geography, integer, integer, text)
FUNCTION	st_asgml(integer, geography, integer, integer, text)
FUNCTION	st_asgml(integer, geometry)
FUNCTION	_st_asgml(integer, geometry, integer)
FUNCTION	st_asgml(integer, geometry, integer)
FUNCTION	st_asgml(integer, geometry, integer, integer)
FUNCTION	_st_asgml(integer, geometry, integer, integer, text)
FUNCTION	st_asgml(integer, geometry, integer, integer, text)
FUNCTION	st_asgml(text)
FUNCTION	st_ashexewkb(geometry)
FUNCTION	st_ashexewkb(geometry, text)
FUNCTION	st_asjpeg(raster, integer, integer)
FUNCTION	st_asjpeg(raster, integer[], integer)
FUNCTION	st_asjpeg(raster, integer, text[])
FUNCTION	st_asjpeg(raster, integer[], text[])
FUNCTION	st_asjpeg(raster, text[])
FUNCTION	st_askml(geography)
FUNCTION	st_askml(geography, integer)
FUNCTION	st_askml(geometry)
FUNCTION	st_askml(geometry, integer)
FUNCTION	st_askml(integer, geography)
FUNCTION	st_askml(integer, geography, integer)
FUNCTION	_st_askml(integer, geography, integer, text)
FUNCTION	st_askml(integer, geography, integer, text)
FUNCTION	st_askml(integer, geometry)
FUNCTION	_st_askml(integer, geometry, integer)
FUNCTION	st_askml(integer, geometry, integer)
FUNCTION	_st_askml(integer, geometry, integer, text)
FUNCTION	st_askml(integer, geometry, integer, text)
FUNCTION	st_askml(text)
FUNCTION	st_aslatlontext(geometry)
FUNCTION	st_aslatlontext(geometry, text)
FUNCTION	_st_aspect4ma(double precision[], text, text[])
FUNCTION	st_aspect(raster, integer, text)
FUNCTION	st_aspng(raster, integer, integer)
FUNCTION	st_aspng(raster, integer[], integer)
FUNCTION	st_aspng(raster, integer, text[])
FUNCTION	st_aspng(raster, integer[], text[])
FUNCTION	st_aspng(raster, text[])
FUNCTION	st_asraster(geometry, double precision, double precision, double precision, double precision, text, double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, double precision, double precision, double precision, double precision, text[], double precision[], double precision[], double precision, double precision, boolean)
FUNCTION	_st_asraster(geometry, double precision, double precision, integer, integer, text[], double precision[], double precision[], double precision, double precision, double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, double precision, double precision, text, double precision, double precision, double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, double precision, double precision, text[], double precision[], double precision[], double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, integer, integer, double precision, double precision, text, double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, integer, integer, double precision, double precision, text[], double precision[], double precision[], double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, integer, integer, text, double precision, double precision, double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, integer, integer, text[], double precision[], double precision[], double precision, double precision, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, raster, text, double precision, double precision, boolean)
FUNCTION	st_asraster(geometry, raster, text[], double precision[], double precision[], boolean)
FUNCTION	st_assvg(geography)
FUNCTION	st_assvg(geography, integer)
FUNCTION	st_assvg(geography, integer, integer)
FUNCTION	st_assvg(geometry)
FUNCTION	st_assvg(geometry, integer)
FUNCTION	st_assvg(geometry, integer, integer)
FUNCTION	st_assvg(text)
FUNCTION	st_astext(geography)
FUNCTION	st_astext(geometry)
FUNCTION	st_astext(text)
FUNCTION	st_astiff(raster, integer[], text, integer)
FUNCTION	st_astiff(raster, integer[], text[], integer)
FUNCTION	st_astiff(raster, text, integer)
FUNCTION	st_astiff(raster, text[], integer)
FUNCTION	st_asx3d(geometry, integer)
FUNCTION	_st_asx3d(integer, geometry, integer, integer, text)
FUNCTION	st_azimuth(geometry, geometry)
FUNCTION	st_bandisnodata(raster)
FUNCTION	st_bandisnodata(raster, boolean)
FUNCTION	st_bandisnodata(raster,integer)
FUNCTION	st_bandisnodata(raster, integer, boolean)
FUNCTION	st_bandmetadata(raster)
FUNCTION	st_bandmetadata(raster, integer)
FUNCTION	st_bandmetadata(raster, integer[])
FUNCTION	st_bandnodatavalue(raster)
FUNCTION	st_bandnodatavalue(raster, integer)
FUNCTION	st_bandpath(raster)
FUNCTION	st_bandpath(raster, integer)
FUNCTION	st_bandpixeltype(raster)
FUNCTION	st_bandpixeltype(raster, integer)
FUNCTION	st_band(raster, integer)
FUNCTION	st_band(raster, integer[])
FUNCTION	st_band(raster, text, character)
FUNCTION	st_bdmpolyfromtext(text, integer)
FUNCTION	st_bdpolyfromtext(text, integer)
FUNCTION	st_below(raster, raster)
FUNCTION	_st_bestsrid(geography)
FUNCTION	_st_bestsrid(geography, geography)
FUNCTION	st_boundary(geometry)
FUNCTION	st_box2d(box3d)
FUNCTION	st_box2d(box3d_extent)
FUNCTION	st_box2d_contain(box2d, box2d)
FUNCTION	st_box2d_contained(box2d, box2d)
FUNCTION	st_box2d(geometry)
FUNCTION	st_box2d_in(cstring)
FUNCTION	st_box2d_intersects(box2d, box2d)
FUNCTION	st_box2d_left(box2d, box2d)
FUNCTION	st_box2d_out(box2d)
FUNCTION	st_box2d_overlap(box2d, box2d)
FUNCTION	st_box2d_overleft(box2d, box2d)
FUNCTION	st_box2d_overright(box2d, box2d)
FUNCTION	st_box2d_right(box2d, box2d)
FUNCTION	st_box2d_same(box2d, box2d)
FUNCTION	st_box3d(box2d)
FUNCTION	st_box3d_extent(box3d_extent)
FUNCTION	st_box3d(geometry)
FUNCTION	st_box3d_in(cstring)
FUNCTION	st_box3d_out(box3d)
FUNCTION	st_box(box3d)
FUNCTION	st_box(geometry)
FUNCTION	st_buffer(geography, double precision)
FUNCTION	st_buffer(geometry, double precision)
FUNCTION	_st_buffer(geometry, double precision, cstring)
FUNCTION	st_buffer(geometry, double precision, integer)
FUNCTION	st_buffer(geometry, double precision, text)
FUNCTION	st_buffer(text, double precision)
FUNCTION	st_buildarea(geometry)
FUNCTION	st_build_histogram2d(histogram2d, text, text)
FUNCTION	st_build_histogram2d(histogram2d, text, text, text)
FUNCTION	st_bytea(geometry)
FUNCTION	st_bytea(raster)
FUNCTION	st_cache_bbox()
FUNCTION	st_centroid(geometry)
FUNCTION	st_changeedgegeom(character varying, integer, public.geometry)
FUNCTION	st_chip_in(cstring)
FUNCTION	st_chip_out(chip)
FUNCTION	st_cleangeometry(geometry)
FUNCTION	st_clip(raster, geometry, boolean)
FUNCTION	st_clip(raster, geometry, double precision, boolean)
FUNCTION	st_clip(raster, integer, geometry, boolean)
FUNCTION	st_clip(raster, integer, geometry, double precision, boolean)
FUNCTION	st_closestpoint(geometry, geometry)
FUNCTION	st_collect_garray(geometry[])
FUNCTION	st_collect(geometry[])
FUNCTION	st_collect(geometry, geometry)
FUNCTION	st_collectionextract(geometry, integer)
FUNCTION	st_collector(geometry, geometry)
FUNCTION	st_combine_bbox(box2d, geometry)
FUNCTION	st_combine_bbox(box3d_extent, geometry)
FUNCTION	st_combine_bbox(box3d, geometry)
FUNCTION	st_compression(chip)
FUNCTION	_st_concavehull(geometry)
FUNCTION	st_concavehull(geometry, double precision, boolean)
FUNCTION	_st_concvehull(geometry)
FUNCTION	st_contained(raster, raster)
FUNCTION	st_contain(raster, raster)
FUNCTION	_st_contains(geometry, geometry)
FUNCTION	st_contains(geometry, geometry)
FUNCTION	_st_containsproperly(geometry, geometry)
FUNCTION	st_containsproperly(geometry, geometry)
FUNCTION	st_convexhull(geometry)
FUNCTION	st_convexhull(raster)
FUNCTION	st_coorddim(geometry)
FUNCTION	st_count(raster, boolean)
FUNCTION	st_count(raster, integer, boolean)
FUNCTION	_st_count(raster, integer, boolean, double precision)
FUNCTION	st_count(text, text, boolean)
FUNCTION	st_count(text, text, integer, boolean)
FUNCTION	_st_count(text, text, integer, boolean, double precision)
FUNCTION	st_coveredby(geography, geography)
FUNCTION	_st_coveredby(geometry, geometry)
FUNCTION	st_coveredby(geometry, geometry)
FUNCTION	st_coveredby(text, text)
FUNCTION	_st_covers(geography, geography)
FUNCTION	st_covers(geography, geography)
FUNCTION	_st_covers(geometry, geometry)
FUNCTION	st_covers(geometry, geometry)
FUNCTION	st_covers(text, text)
FUNCTION	st_create_histogram2d(box2d, integer)
FUNCTION	st_createtopogeo(character varying, public.geometry)
FUNCTION	_st_crosses(geometry, geometry)
FUNCTION	st_crosses(geometry, geometry)
FUNCTION	st_curvetoline(geometry)
FUNCTION	st_curvetoline(geometry, integer)
FUNCTION	st_datatype(chip)
FUNCTION	_st_dfullywithin(geometry, geometry, double precision)
FUNCTION	st_dfullywithin(geometry, geometry, double precision)
FUNCTION	st_difference(geometry, geometry)
FUNCTION	st_dimension(geometry)
FUNCTION	st_disjoint(geometry, geometry)
FUNCTION	st_distance(geography, geography)
FUNCTION	st_distance(geography, geography, boolean)
FUNCTION	_st_distance(geography, geography, double precision, boolean)
FUNCTION	st_distance(geometry, geometry)
FUNCTION	st_distance_sphere(geometry, geometry)
FUNCTION	st_distance_spheroid(geometry, geometry, spheroid)
FUNCTION	st_distance(text, text)
FUNCTION	st_dropbbox(geometry)
FUNCTION	st_dumpaspolygons(raster)
FUNCTION	st_dumpaspolygons(raster, integer)
FUNCTION	_st_dumpaswktpolygons(raster, integer)
FUNCTION	st_dump(geometry)
FUNCTION	st_dumppoints(geometry)
FUNCTION	_st_dumppoints(geometry, integer[])
FUNCTION	st_dumprings(geometry)
FUNCTION	st_dwithin(geography, geography, double precision)
FUNCTION	_st_dwithin(geography, geography, double precision, boolean)
FUNCTION	st_dwithin(geography, geography, double precision, boolean)
FUNCTION	_st_dwithin(geometry, geometry, double precision)
FUNCTION	st_dwithin(geometry, geometry, double precision)
FUNCTION	st_dwithin(text, text, double precision)
FUNCTION	st_endpoint(geometry)
FUNCTION	st_envelope(geometry)
FUNCTION	st_envelope(raster)
FUNCTION	_st_equals(geometry, geometry)
FUNCTION	st_equals(geometry, geometry)
FUNCTION	st_estimated_extent(text, text)
FUNCTION	st_estimated_extent(text, text, text)
FUNCTION	st_estimate_histogram2d(histogram2d, box2d)
FUNCTION	st_expand(box2d, double precision)
FUNCTION	st_expand(box3d, double precision)
FUNCTION	_st_expand(geography, double precision)
FUNCTION	st_expand(geometry, double precision)
FUNCTION	st_explode_histogram2d(histogram2d, text)
FUNCTION	st_exteriorring(geometry)
FUNCTION	st_factor(chip)
FUNCTION	st_find_extent(text, text)
FUNCTION	st_find_extent(text, text, text)
FUNCTION	st_flipcoordinates(geometry)
FUNCTION	st_force_2d(geometry)
FUNCTION	st_force_3d(geometry)
FUNCTION	st_force_3dm(geometry)
FUNCTION	st_force_3dz(geometry)
FUNCTION	st_force_4d(geometry)
FUNCTION	st_force_collection(geometry)
FUNCTION	st_forcerhr(geometry)
FUNCTION	st_gdaldrivers()
FUNCTION	st_geogfromtext(text)
FUNCTION	st_geogfromwkb(bytea)
FUNCTION	st_geographyfromtext(text)
FUNCTION	st_geohash(geometry)
FUNCTION	st_geohash(geometry, integer)
FUNCTION	st_geom_accum(geometry[], geometry)
FUNCTION	st_geomcollfromtext(text)
FUNCTION	st_geomcollfromtext(text, integer)
FUNCTION	st_geomcollfromwkb(bytea)
FUNCTION	st_geomcollfromwkb(bytea, integer)
FUNCTION	st_geometry_above(geometry, geometry)
FUNCTION	st_geometry_analyze(internal)
FUNCTION	st_geometry_below(geometry, geometry)
FUNCTION	st_geometry(box2d)
FUNCTION	st_geometry(box3d)
FUNCTION	st_geometry(box3d_extent)
FUNCTION	st_geometry(bytea)
FUNCTION	st_geometry(chip)
FUNCTION	st_geometry_cmp(geometry, geometry)
FUNCTION	st_geometry_contained(geometry, geometry)
FUNCTION	st_geometry_contain(geometry, geometry)
FUNCTION	st_geometry_eq(geometry, geometry)
FUNCTION	st_geometryfromtext(text)
FUNCTION	st_geometryfromtext(text, integer)
FUNCTION	st_geometry_ge(geometry, geometry)
FUNCTION	st_geometry_gt(geometry, geometry)
FUNCTION	st_geometry_in(cstring)
FUNCTION	st_geometry_left(geometry, geometry)
FUNCTION	st_geometry_le(geometry, geometry)
FUNCTION	st_geometry_lt(geometry, geometry)
FUNCTION	st_geometryn(geometry, integer)
FUNCTION	st_geometry_out(geometry)
FUNCTION	st_geometry_overabove(geometry, geometry)
FUNCTION	st_geometry_overbelow(geometry, geometry)
FUNCTION	st_geometry_overlap(geometry, geometry)
FUNCTION	st_geometry_overleft(geometry, geometry)
FUNCTION	st_geometry_overright(geometry, geometry)
FUNCTION	st_geometry_recv(internal)
FUNCTION	st_geometry_right(geometry, geometry)
FUNCTION	st_geometry_same(geometry, geometry)
FUNCTION	st_geometry_send(geometry)
FUNCTION	st_geometry(text)
FUNCTION	st_geometrytype(geometry)
FUNCTION	st_geometrytype(topogeometry)
FUNCTION	st_geomfromewkb(bytea)
FUNCTION	st_geomfromewkt(text)
FUNCTION	st_geomfromgeojson(text)
FUNCTION	st_geomfromgml(text)
FUNCTION	_st_geomfromgml(text, integer)
FUNCTION	st_geomfromgml(text, integer)
FUNCTION	st_geomfromkml(text)
FUNCTION	st_geomfromtext(text)
FUNCTION	st_geomfromtext(text, integer)
FUNCTION	st_geomfromwkb(bytea)
FUNCTION	st_geomfromwkb(bytea, integer)
FUNCTION	st_georeference(raster)
FUNCTION	st_georeference(raster, text)
FUNCTION	st_getfaceedges(character varying, integer)
FUNCTION	st_getfacegeometry(character varying, integer)
FUNCTION	st_gmltosql(text)
FUNCTION	st_gmltosql(text, integer)
FUNCTION	st_hasarc(geometry)
FUNCTION	st_hasbbox(geometry)
FUNCTION	st_hasnoband(raster)
FUNCTION	st_hasnoband(raster, integer)
FUNCTION	st_hausdorffdistance(geometry, geometry)
FUNCTION	st_hausdorffdistance(geometry, geometry, double precision)
FUNCTION	st_height(chip)
FUNCTION	st_height(raster)
FUNCTION	_st_hillshade4ma(double precision[], text, text[])
FUNCTION	st_hillshade(raster, integer, text, double precision, double precision, double precision, double precision)
FUNCTION	st_histogram2d_in(cstring)
FUNCTION	st_histogram2d_out(histogram2d)
FUNCTION	_st_histogram(raster, integer, boolean, double precision, integer, double precision[], boolean, double precision, double precision)
FUNCTION	st_histogram(raster, integer, boolean, integer, boolean)
FUNCTION	st_histogram(raster, integer, boolean, integer, double precision[], boolean)
FUNCTION	st_histogram(raster, integer, integer, boolean)
FUNCTION	st_histogram(raster, integer, integer, double precision[], boolean)
FUNCTION	_st_histogram(text, text, integer, boolean, double precision, integer, double precision[], boolean)
FUNCTION	st_histogram(text, text, integer, boolean, integer, boolean)
FUNCTION	st_histogram(text, text, integer, boolean, integer, double precision[], boolean)
FUNCTION	st_histogram(text, text, integer, integer, boolean)
FUNCTION	st_histogram(text, text, integer, integer, double precision[], boolean)
FUNCTION	st_inittopogeo(character varying)
FUNCTION	st_interiorringn(geometry, integer)
FUNCTION	st_intersection(geography, geography)
FUNCTION	st_intersection(geometry, geometry)
FUNCTION	st_intersection(geometry,raster)
FUNCTION	st_intersection(geometry, raster, integer)
FUNCTION	st_intersection(raster, geometry)
FUNCTION	st_intersection(raster,geometry,regprocedure)
FUNCTION	st_intersection(raster,geometry,text,regprocedure)
FUNCTION	st_intersection(raster, integer, geometry)
FUNCTION	st_intersection(raster,integer,geometry,regprocedure)
FUNCTION	st_intersection(raster,integer,geometry,text,regprocedure)
FUNCTION	st_intersection(raster,integer,raster,integer,regprocedure)
FUNCTION	st_intersection(raster,integer,raster,integer,text,regprocedure)
FUNCTION	_st_intersection(raster,integer,raster,integer,text,text,regprocedure)
FUNCTION	st_intersection(raster,raster,regprocedure)
FUNCTION	st_intersection(raster,raster,text,regprocedure)
FUNCTION	st_intersection(text, text)
FUNCTION	st_intersects(geography, geography)
FUNCTION	_st_intersects(geometry, geometry)
FUNCTION	st_intersects(geometry, geometry)
FUNCTION	st_intersects(geometry,raster)
FUNCTION	st_intersects(geometry,raster,boolean)
FUNCTION	_st_intersects(geometry, raster, integer)
FUNCTION	st_intersects(geometry, raster, integer)
FUNCTION	_st_intersects(geometry, raster, integer, boolean)
FUNCTION	st_intersects(geometry,raster,integer,boolean)
FUNCTION	st_intersects(raster,boolean,geometry)
FUNCTION	st_intersects(raster,geometry)
FUNCTION	_st_intersects(raster, geometry, integer)
FUNCTION	st_intersects(raster, geometry, integer)
FUNCTION	st_intersects(raster,integer,boolean,geometry)
FUNCTION	st_intersects(raster, integer, geometry)
FUNCTION	_st_intersects(raster, integer, raster, integer)
FUNCTION	st_intersects(raster, integer, raster, integer)
FUNCTION	st_intersects(raster, raster)
FUNCTION	st_intersects(text, text)
FUNCTION	st_isclosed(geometry)
FUNCTION	st_iscollection(geometry)
FUNCTION	st_isempty(geometry)
FUNCTION	st_isempty(raster)
FUNCTION	st_isring(geometry)
FUNCTION	st_issimple(geometry)
FUNCTION	st_isvaliddetail(geometry)
FUNCTION	st_isvaliddetail(geometry, integer)
FUNCTION	st_isvalid(geometry)
FUNCTION	st_isvalid(geometry, integer)
FUNCTION	st_isvalidreason(geometry)
FUNCTION	st_isvalidreason(geometry, integer)
FUNCTION	st_left(raster, raster)
FUNCTION	st_length2d(geometry)
FUNCTION	st_length2d_spheroid(geometry, spheroid)
FUNCTION	st_length3d(geometry)
FUNCTION	st_length3d_spheroid(geometry,spheroid)
FUNCTION	st_length(geography, boolean)
FUNCTION	st_length(geometry)
FUNCTION	st_length_spheroid(geometry, spheroid)
FUNCTION	st_length(text)
FUNCTION	_st_linecrossingdirection(geometry, geometry)
FUNCTION	st_linecrossingdirection(geometry, geometry)
FUNCTION	st_linefrommultipoint(geometry)
FUNCTION	st_linefromtext(text)
FUNCTION	st_linefromtext(text, integer)
FUNCTION	st_linefromwkb(bytea)
FUNCTION	st_linefromwkb(bytea, integer)
FUNCTION	st_line_interpolate_point(geometry, double precision)
FUNCTION	st_line_locate_point(geometry, geometry)
FUNCTION	st_linemerge(geometry)
FUNCTION	st_linestringfromwkb(bytea)
FUNCTION	st_linestringfromwkb(bytea, integer)
FUNCTION	st_line_substring(geometry, double precision, double precision)
FUNCTION	st_linetocurve(geometry)
FUNCTION	st_locate_along_measure(geometry, double precision)
FUNCTION	st_locatebetweenelevations(geometry, double precision, double precision)
FUNCTION	st_locate_between_measures(geometry, double precision, double precision)
FUNCTION	_st_longestline(geometry, geometry)
FUNCTION	st_longestline(geometry, geometry)
FUNCTION	st_makebox2d(geometry, geometry)
FUNCTION	st_makebox3d(geometry,geometry)
FUNCTION	st_makeemptyraster(integer, integer, double precision, double precision, double precision)
FUNCTION	st_makeemptyraster(integer,integer,doubleprecision,doubleprecision,doubleprecision,doubleprecision,doubleprecision,doubleprecision)
FUNCTION	st_makeemptyraster(integer, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer)
FUNCTION	st_makeemptyraster(raster)
FUNCTION	st_makeenvelope(double precision, double precision, double precision, double precision)
FUNCTION	st_makeenvelope(double precision, double precision, double precision, double precision, integer)
FUNCTION	st_makeline_garray(geometry[])
FUNCTION	st_makeline(geometry[])
FUNCTION	st_makeline(geometry, geometry)
FUNCTION	st_makepoint(double precision, double precision)
FUNCTION	st_makepoint(double precision, double precision, double precision)
FUNCTION	st_makepoint(double precision, double precision, double precision, double precision)
FUNCTION	st_makepointm(double precision, double precision, double precision)
FUNCTION	st_makepolygon(geometry)
FUNCTION	st_makepolygon(geometry, geometry[])
FUNCTION	st_makevalid(geometry)
FUNCTION	_st_mapalgebra4unionfinal1(raster)
FUNCTION	_st_mapalgebra4unionstate(raster,raster)
FUNCTION	_st_mapalgebra4unionstate(raster,raster,integer)
FUNCTION	_st_mapalgebra4unionstate(raster,raster,integer,text)
FUNCTION	_st_mapalgebra4unionstate(raster,raster,text)
FUNCTION	_st_mapalgebra4unionstate(raster,raster,text,text,text,doubleprecision,text,text,text,doubleprecision)
FUNCTION	st_mapalgebraexpr(raster, integer, raster, integer, text, text, text, text, text, double precision)
FUNCTION	st_mapalgebraexpr(raster, integer, text, text, double precision)
FUNCTION	st_mapalgebraexpr(raster,integer,text,text,text)
FUNCTION	st_mapalgebraexpr(raster, raster, text, text, text, text, text, double precision)
FUNCTION	st_mapalgebraexpr(raster, text, text, double precision)
FUNCTION	st_mapalgebraexpr(raster,text,text,text)
FUNCTION	st_mapalgebrafctngb(raster, integer, text, integer, integer, regprocedure, text, text[])
FUNCTION	st_mapalgebrafct(raster, integer, raster, integer, regprocedure, text, text, text[])
FUNCTION	st_mapalgebrafct(raster, integer, regprocedure)
FUNCTION	st_mapalgebrafct(raster, integer, regprocedure, text[])
FUNCTION	st_mapalgebrafct(raster, integer, text, regprocedure)
FUNCTION	st_mapalgebrafct(raster, integer, text, regprocedure, text[])
FUNCTION	st_mapalgebrafct(raster, raster, regprocedure, text, text, text[])
FUNCTION	st_mapalgebrafct(raster, regprocedure)
FUNCTION	st_mapalgebrafct(raster, regprocedure, text[])
FUNCTION	st_mapalgebrafct(raster, text, regprocedure)
FUNCTION	st_mapalgebrafct(raster, text, regprocedure, text[])
FUNCTION	st_mapalgebra(raster,integer,text)
FUNCTION	st_mapalgebra(raster,integer,text,text)
FUNCTION	st_mapalgebra(raster, integer, text, text, text)
FUNCTION	st_mapalgebra(raster,text)
FUNCTION	st_mapalgebra(raster,text,text)
FUNCTION	st_mapalgebra(raster,text,text,text)
FUNCTION	st_max4ma(double precision[], text, text[])
FUNCTION	_st_maxdistance(geometry, geometry)
FUNCTION	st_max_distance(geometry, geometry)
FUNCTION	st_maxdistance(geometry, geometry)
FUNCTION	st_mean4ma(double precision[], text, text[])
FUNCTION	st_mem_size(geometry)
FUNCTION	st_metadata(raster)
FUNCTION	st_m(geometry)
FUNCTION	st_min4ma(double precision[], text, text[])
FUNCTION	st_minimumboundingcircle(geometry)
FUNCTION	st_minimumboundingcircle(geometry, integer)
FUNCTION	st_minpossibleval(text)
FUNCTION	st_minpossiblevalue(text)
FUNCTION	st_mlinefromtext(text)
FUNCTION	st_mlinefromtext(text, integer)
FUNCTION	st_mlinefromwkb(bytea)
FUNCTION	st_mlinefromwkb(bytea, integer)
FUNCTION	st_modedgeheal(character varying, integer, integer)
FUNCTION	st_modedgesplit(character varying, integer, public.geometry)
FUNCTION	st_modedgessplit(charactervarying,integer,public.geometry)
FUNCTION	st_moveisonode(character varying, integer, public.geometry)
FUNCTION	st_mpointfromtext(text)
FUNCTION	st_mpointfromtext(text, integer)
FUNCTION	st_mpointfromwkb(bytea)
FUNCTION	st_mpointfromwkb(bytea, integer)
FUNCTION	st_mpolyfromtext(text)
FUNCTION	st_mpolyfromtext(text, integer)
FUNCTION	st_mpolyfromwkb(bytea)
FUNCTION	st_mpolyfromwkb(bytea, integer)
FUNCTION	st_multi(geometry)
FUNCTION	st_multilinefromwkb(bytea)
FUNCTION	st_multilinestringfromtext(text)
FUNCTION	st_multilinestringfromtext(text, integer)
FUNCTION	st_multipointfromtext(text)
FUNCTION	st_multipointfromwkb(bytea)
FUNCTION	st_multipointfromwkb(bytea, integer)
FUNCTION	st_multipolyfromwkb(bytea)
FUNCTION	st_multipolyfromwkb(bytea, integer)
FUNCTION	st_multipolygonfromtext(text)
FUNCTION	st_multipolygonfromtext(text, integer)
FUNCTION	st_ndims(geometry)
FUNCTION	st_newedgeheal(character varying, integer, integer)
FUNCTION	st_newedgessplit(character varying, integer, public.geometry)
FUNCTION	st_node(geometry)
FUNCTION	st_noop(geometry)
FUNCTION	st_npoints(geometry)
FUNCTION	st_nrings(geometry)
FUNCTION	st_numbands(raster)
FUNCTION	st_numgeometries(geometry)
FUNCTION	st_numinteriorring(geometry)
FUNCTION	st_numinteriorrings(geometry)
FUNCTION	st_numpatches(geometry)
FUNCTION	st_numpoints(geometry)
FUNCTION	st_offsetcurve(geometry,doubleprecision,cstring)
FUNCTION	st_offsetcurve(geometry, double precision, text)
FUNCTION	_st_orderingequals(geometry, geometry)
FUNCTION	st_orderingequals(geometry, geometry)
FUNCTION	st_overabove(raster, raster)
FUNCTION	st_overbelow(raster, raster)
FUNCTION	st_overlap(raster, raster)
FUNCTION	_st_overlaps(geometry, geometry)
FUNCTION	st_overlaps(geometry, geometry)
FUNCTION	st_overleft(raster, raster)
FUNCTION	st_overright(raster, raster)
FUNCTION	st_patchn(geometry, integer)
FUNCTION	st_perimeter2d(geometry)
FUNCTION	st_perimeter3d(geometry)
FUNCTION	st_perimeter(geography, boolean)
FUNCTION	st_perimeter(geometry)
FUNCTION	st_pixelaspolygon(raster, integer, integer)
FUNCTION	st_pixelaspolygon(raster, integer, integer, integer)
FUNCTION	st_pixelaspolygons(raster, integer)
FUNCTION	st_pixelheight(raster)
FUNCTION	st_pixelwidth(raster)
FUNCTION	st_point(double precision, double precision)
FUNCTION	st_pointfromtext(text)
FUNCTION	st_pointfromtext(text, integer)
FUNCTION	st_pointfromwkb(bytea)
FUNCTION	st_pointfromwkb(bytea, integer)
FUNCTION	st_point_inside_circle(geometry, double precision, double precision, double precision)
FUNCTION	st_pointn(geometry)
FUNCTION	st_pointn(geometry, integer)
FUNCTION	st_pointonsurface(geometry)
FUNCTION	_st_pointoutside(geography)
FUNCTION	st_polyfromtext(text)
FUNCTION	st_polyfromtext(text, integer)
FUNCTION	st_polyfromwkb(bytea)
FUNCTION	st_polyfromwkb(bytea, integer)
FUNCTION	st_polygonfromtext(text)
FUNCTION	st_polygonfromtext(text, integer)
FUNCTION	st_polygonfromwkb(bytea)
FUNCTION	st_polygonfromwkb(bytea, integer)
FUNCTION	st_polygon(geometry, integer)
FUNCTION	st_polygonize_garray(geometry[])
FUNCTION	st_polygonize(geometry[])
FUNCTION	st_polygon(raster)
FUNCTION	st_polygon(raster, integer)
FUNCTION	st_postgis_gist_joinsel(internal, oid, internal, smallint)
FUNCTION	st_postgis_gist_sel(internal, oid, internal, integer)
FUNCTION	st_quantile(raster, boolean, double precision)
FUNCTION	st_quantile(raster, double precision)
FUNCTION	st_quantile(raster, double precision[])
FUNCTION	st_quantile(raster, integer, boolean, double precision)
FUNCTION	st_quantile(raster, integer, boolean, double precision[])
FUNCTION	_st_quantile(raster, integer, boolean, double precision, double precision[])
FUNCTION	st_quantile(raster, integer, double precision)
FUNCTION	st_quantile(raster, integer, double precision[])
FUNCTION	st_quantile(text, text, boolean, double precision)
FUNCTION	st_quantile(text, text, double precision)
FUNCTION	st_quantile(text, text, double precision[])
FUNCTION	st_quantile(text, text, integer, boolean, double precision)
FUNCTION	st_quantile(text, text, integer, boolean, double precision[])
FUNCTION	_st_quantile(text, text, integer, boolean, double precision, double precision[])
FUNCTION	st_quantile(text, text, integer, double precision)
FUNCTION	st_quantile(text, text, integer, double precision[])
FUNCTION	st_range4ma(double precision[], text, text[])
FUNCTION	st_raster2worldcoordx(raster, integer)
FUNCTION	st_raster2worldcoordx(raster, integer, integer)
FUNCTION	st_raster2worldcoordy(raster, integer)
FUNCTION	st_raster2worldcoordy(raster, integer, integer)
FUNCTION	st_reclass(raster, integer, text, text, double precision)
FUNCTION	_st_reclass(raster, reclassarg[])
FUNCTION	st_reclass(raster, reclassarg[])
FUNCTION	st_reclass(raster, text, text)
FUNCTION	st_relate(geometry, geometry)
FUNCTION	st_relate(geometry, geometry, integer)
FUNCTION	st_relate(geometry, geometry, text)
FUNCTION	st_relatematch(text, text)
FUNCTION	st_remedgemodface(character varying, integer)
FUNCTION	st_remedgenewface(character varying, integer)
FUNCTION	st_remisonode(character varying, integer)
FUNCTION	st_removeisoedge(character varying, integer)
FUNCTION	st_removeisonode(character varying, integer)
FUNCTION	st_removepoint(geometry, integer)
FUNCTION	st_removerepeatedpoints(geometry)
FUNCTION	st_resample(raster, integer, double precision, double precision, double precision, double precision, double precision, double precision, text, double precision)
FUNCTION	st_resample(raster, integer, integer, integer, double precision, double precision, double precision, double precision, text, double precision)
FUNCTION	st_resample(raster, raster, boolean, text, double precision)
FUNCTION	st_resample(raster,raster,text,doubleprecision)
FUNCTION	st_resample(raster, raster, text, double precision, boolean)
FUNCTION	_st_resample(raster, text, double precision, integer, double precision, double precision, double precision, double precision, double precision, double precision)
FUNCTION	_st_resample(raster, text, double precision, integer, double precision, double precision, double precision, double precision, double precision, double precision, integer, integer)
FUNCTION	st_rescale(raster, double precision, double precision, text, double precision)
FUNCTION	st_rescale(raster, double precision, text, double precision)
FUNCTION	st_reskew(raster, double precision, double precision, text, double precision)
FUNCTION	st_reskew(raster, double precision, text, double precision)
FUNCTION	st_reverse(geometry)
FUNCTION	st_right(raster, raster)
FUNCTION	st_rotate(geometry, double precision)
FUNCTION	st_rotatex(geometry, double precision)
FUNCTION	st_rotatey(geometry, double precision)
FUNCTION	st_rotatez(geometry, double precision)
FUNCTION	st_rotation(raster)
FUNCTION	st_samealignment(double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision, double precision)
FUNCTION	st_samealignment(raster, raster)
FUNCTION	st_same(raster, raster)
FUNCTION	st_scale(geometry, double precision, double precision)
FUNCTION	st_scale(geometry, double precision, double precision, double precision)
FUNCTION	st_scalex(raster)
FUNCTION	st_scaley(raster)
FUNCTION	st_segmentize(geometry, double precision)
FUNCTION	st_setbandisnodata(raster)
FUNCTION	st_setbandisnodata(raster, integer)
FUNCTION	st_setbandnodatavalue(raster, double precision)
FUNCTION	st_setbandnodatavalue(raster,integer,doubleprecision)
FUNCTION	st_setbandnodatavalue(raster, integer, double precision, boolean)
FUNCTION	st_setfactor(chip, real)
FUNCTION	st_setgeoreference(raster,text)
FUNCTION	st_setgeoreference(raster, text, text)
FUNCTION	st_setpoint(geometry, integer, geometry)
FUNCTION	st_setrotation(raster, double precision)
FUNCTION	st_setscale(raster, double precision)
FUNCTION	st_setscale(raster, double precision, double precision)
FUNCTION	st_setskew(raster, double precision)
FUNCTION	st_setskew(raster, double precision, double precision)
FUNCTION	st_setsrid(geometry, integer)
FUNCTION	st_setsrid(raster, integer)
FUNCTION	st_setupperleft(raster, double precision, double precision)
FUNCTION	st_setvalue(raster, geometry, double precision)
FUNCTION	st_setvalue(raster, integer, geometry, double precision)
FUNCTION	st_setvalue(raster, integer, integer, double precision)
FUNCTION	st_setvalue(raster, integer, integer, integer, double precision)
FUNCTION	st_sharedpaths(geometry, geometry)
FUNCTION	st_shift_longitude(geometry)
FUNCTION	st_shortestline(geometry, geometry)
FUNCTION	st_simplify(geometry, double precision)
FUNCTION	st_simplifypreservetopology(geometry, double precision)
FUNCTION	st_skewx(raster)
FUNCTION	st_skewy(raster)
FUNCTION	_st_slope4ma(double precision[], text, text[])
FUNCTION	st_slope(raster, integer, text)
FUNCTION	st_snap(geometry, geometry, double precision)
FUNCTION	st_snaptogrid(geometry, double precision)
FUNCTION	st_snaptogrid(geometry, double precision, double precision)
FUNCTION	st_snaptogrid(geometry, double precision, double precision, double precision, double precision)
FUNCTION	st_snaptogrid(geometry, geometry, double precision, double precision, double precision, double precision)
FUNCTION	st_snaptogrid(raster, double precision, double precision, double precision, double precision, text, double precision)
FUNCTION	st_snaptogrid(raster, double precision, double precision, double precision, text, double precision)
FUNCTION	st_snaptogrid(raster, double precision, double precision, text, double precision, double precision, double precision)
FUNCTION	st_spheroid_in(cstring)
FUNCTION	st_spheroid_out(spheroid)
FUNCTION	st_split(geometry, geometry)
FUNCTION	st_srid(chip)
FUNCTION	st_srid(geometry)
FUNCTION	st_srid(raster)
FUNCTION	st_startpoint(geometry)
FUNCTION	st_sum4ma(double precision[], text, text[])
FUNCTION	st_summary(geometry)
FUNCTION	st_summarystats(raster, boolean)
FUNCTION	st_summarystats(raster, integer, boolean)
FUNCTION	_st_summarystats(raster, integer, boolean, double precision)
FUNCTION	st_summarystats(text, text, boolean)
FUNCTION	st_summarystats(text, text, integer, boolean)
FUNCTION	_st_summarystats(text, text, integer, boolean, double precision)
FUNCTION	st_symdifference(geometry, geometry)
FUNCTION	st_symmetricdifference(geometry, geometry)
FUNCTION	st_text(boolean)
FUNCTION	st_text(geometry)
FUNCTION	_st_touches(geometry, geometry)
FUNCTION	st_touches(geometry, geometry)
FUNCTION	st_transform(geometry, integer)
FUNCTION	st_transform(raster, integer, double precision, double precision, text, double precision)
FUNCTION	st_transform(raster, integer, double precision, text, double precision)
FUNCTION	st_transform(raster, integer, text, double precision, double precision, double precision)
FUNCTION	st_translate(geometry, double precision, double precision)
FUNCTION	st_translate(geometry, double precision, double precision, double precision)
FUNCTION	st_transscale(geometry, double precision, double precision, double precision, double precision)
FUNCTION	st_unaryunion(geometry)
FUNCTION	st_union(geometry[])
FUNCTION	st_union(geometry, geometry)
FUNCTION	st_unite_garray(geometry[])
FUNCTION	st_upperleftx(raster)
FUNCTION	st_upperlefty(raster)
FUNCTION	st_valuecount(raster, double precision, double precision)
FUNCTION	st_valuecount(raster, double precision[], double precision)
FUNCTION	_st_valuecount(raster, integer, boolean, double precision[], double precision)
FUNCTION	st_valuecount(raster, integer, boolean, double precision, double precision)
FUNCTION	st_valuecount(raster, integer, boolean, double precision[], double precision)
FUNCTION	st_valuecount(raster, integer, double precision, double precision)
FUNCTION	st_valuecount(raster, integer, double precision[], double precision)
FUNCTION	st_valuecount(text, text, double precision, double precision)
FUNCTION	st_valuecount(text, text, double precision[], double precision)
FUNCTION	_st_valuecount(text, text, integer, boolean, double precision[], double precision)
FUNCTION	st_valuecount(text, text, integer, boolean, double precision, double precision)
FUNCTION	st_valuecount(text, text, integer, boolean, double precision[], double precision)
FUNCTION	st_valuecount(text, text, integer, double precision, double precision)
FUNCTION	st_valuecount(text, text, integer, double precision[], double precision)
FUNCTION	st_valuepercent(raster, double precision, double precision)
FUNCTION	st_valuepercent(raster, double precision[], double precision)
FUNCTION	st_valuepercent(raster, integer, boolean, double precision, double precision)
FUNCTION	st_valuepercent(raster, integer, boolean, double precision[], double precision)
FUNCTION	st_valuepercent(raster, integer, double precision, double precision)
FUNCTION	st_valuepercent(raster, integer, double precision[], double precision)
FUNCTION	st_valuepercent(text, text, double precision, double precision)
FUNCTION	st_valuepercent(text, text, double precision[], double precision)
FUNCTION	st_valuepercent(text, text, integer, boolean, double precision, double precision)
FUNCTION	st_valuepercent(text, text, integer, boolean, double precision[], double precision)
FUNCTION	st_valuepercent(text, text, integer, double precision, double precision)
FUNCTION	st_valuepercent(text, text, integer, double precision[], double precision)
FUNCTION	st_value(raster,geometry)
FUNCTION	st_value(raster, geometry, boolean)
FUNCTION	st_value(raster,integer,geometry)
FUNCTION	st_value(raster, integer, geometry, boolean)
FUNCTION	st_value(raster,integer,integer)
FUNCTION	st_value(raster, integer, integer, boolean)
FUNCTION	st_value(raster,integer,integer,integer)
FUNCTION	st_value(raster, integer, integer, integer, boolean)
FUNCTION	st_width(chip)
FUNCTION	st_width(raster)
FUNCTION	_st_within(geometry, geometry)
FUNCTION	st_within(geometry, geometry)
FUNCTION	st_wkbtosql(bytea)
FUNCTION	st_wkttosql(text)
FUNCTION	st_world2rastercoordx(raster, double precision)
FUNCTION	st_world2rastercoordx(raster, double precision, double precision)
FUNCTION	st_world2rastercoordx(raster, geometry)
FUNCTION	st_world2rastercoordy(raster, double precision)
FUNCTION	st_world2rastercoordy(raster, double precision, double precision)
FUNCTION	st_world2rastercoordy(raster, geometry)
FUNCTION	st_x(geometry)
FUNCTION	st_xmax(box3d)
FUNCTION	st_xmin(box3d)
FUNCTION	st_y(geometry)
FUNCTION	st_ymax(box3d)
FUNCTION	st_ymin(box3d)
FUNCTION	st_z(geometry)
FUNCTION	st_zmax(box3d)
FUNCTION	st_zmflag(geometry)
FUNCTION	st_zmin(box3d)
FUNCTION	summary(geometry)
FUNCTION	symdifference(geometry, geometry)
FUNCTION	symmetricdifference(geometry, geometry)
FUNCTION	text(boolean)
FUNCTION	text(geometry)
FUNCTION	topoelementarray_append(topoelementarray, topoelement)
FUNCTION	topogeo_addlinestring(character varying, public.geometry)
FUNCTION	topogeo_addpoint(character varying, public.geometry, integer, integer)
FUNCTION	topogeo_addpolygon(character varying, public.geometry)
FUNCTION	topologysummary(character varying)
FUNCTION	touches(geometry, geometry)
FUNCTION	transform_geometry(geometry, text, text, integer)
FUNCTION	transform(geometry, integer)
FUNCTION	translate(geometry, double precision, double precision)
FUNCTION	translate(geometry, double precision, double precision, double precision)
FUNCTION	transscale(geometry, double precision, double precision, double precision, double precision)
FUNCTION	unite_garray(geometry[])
FUNCTION	unlockrows(text)
FUNCTION	updategeometrysrid(character varying, character varying, character varying, character varying, integer)
FUNCTION	updategeometrysrid(character varying, character varying, character varying, integer)
FUNCTION	updategeometrysrid(character varying, character varying, integer)
FUNCTION	update_geometry_stats()
FUNCTION	update_geometry_stats(character varying, character varying)
FUNCTION	validatetopology(character varying)
FUNCTION	width(chip)
FUNCTION	within(geometry, geometry)
FUNCTION	x(geometry)
FUNCTION	xmax(box3d)
FUNCTION	xmin(box3d)
FUNCTION	y(geometry)
FUNCTION	ymax(box3d)
FUNCTION	ymin(box3d)
FUNCTION	z(geometry)
FUNCTION	zmax(box3d)
FUNCTION	zmflag(geometry)
FUNCTION	zmin(box3d)
OPERATOR CLASS	btree_geography_ops
OPERATOR CLASS	btree_geometry_ops
OPERATOR CLASS	gist_geography_ops
OPERATOR CLASS	gist_geometry_ops
OPERATOR CLASS	gist_geometry_ops_2d
OPERATOR CLASS	gist_geometry_ops_nd
OPERATOR	~=(geography, geography)
OPERATOR	~(geography, geography)
OPERATOR	<<|(geography, geography)
OPERATOR	<<(geography, geography)
OPERATOR	<=(geography, geography)
OPERATOR	<(geography, geography)
OPERATOR	=(geography, geography)
OPERATOR	>=(geography, geography)
OPERATOR	>>(geography, geography)
OPERATOR	>(geography, geography)
OPERATOR	|>>(geography, geography)
OPERATOR	|&>(geography, geography)
OPERATOR	@(geography, geography)
OPERATOR	&<|(geography, geography)
OPERATOR	&<(geography, geography)
OPERATOR	&>(geography, geography)
OPERATOR	&&(geography, geography)
OPERATOR	&&&(geography, geography)
OPERATOR	~=(geometry, geometry)
OPERATOR	~(geometry, geometry)
OPERATOR	<<|(geometry, geometry)
OPERATOR	<<(geometry, geometry)
OPERATOR	<=(geometry, geometry)
OPERATOR	<(geometry, geometry)
OPERATOR	=(geometry, geometry)
OPERATOR	>=(geometry, geometry)
OPERATOR	>>(geometry, geometry)
OPERATOR	>(geometry, geometry)
OPERATOR	|>>(geometry, geometry)
OPERATOR	|&>(geometry, geometry)
OPERATOR	@(geometry, geometry)
OPERATOR	&<|(geometry, geometry)
OPERATOR	&<(geometry, geometry)
OPERATOR	&>(geometry, geometry)
OPERATOR	&&(geometry, geometry)
OPERATOR	&&&(geometry, geometry)
OPERATOR	~=(raster,raster)
OPERATOR	~(raster,raster)
OPERATOR	<<|(raster,raster)
OPERATOR	<<(raster,raster)
OPERATOR	>>(raster,raster)
OPERATOR	|>>(raster,raster)
OPERATOR	|&>(raster,raster)
OPERATOR	@(raster,raster)
OPERATOR	&<|(raster,raster)
OPERATOR	&<(raster,raster)
OPERATOR	&>(raster,raster)
OPERATOR	&&(raster,raster)
PROCEDURALLANGUAGE	plpgsql
SCHEMA	topology
SEQUENCE topology_id_seq
SHELLTYPE	box2d
SHELLTYPE	box2df
SHELLTYPE	box3d
SHELLTYPE	box3d_extent
SHELLTYPE	chip
SHELLTYPE	geography
SHELLTYPE	geometry
SHELLTYPE	gidx
SHELLTYPE	pgis_abs
SHELLTYPE	raster
SHELLTYPE	spheroid
TABLE	DATA	geography_columns
TABLE	DATA	geometry_columns
TABLE	DATA	raster_columns
TABLE	DATA	raster_overviews
TABLE	geography_columns
TABLE	geometry_columns
TABLE	layer
TABLE	raster_columns
TABLE	raster_overviews
TABLE	spatial_ref_sys
TABLE	topology
TRIGGER layer_integrity_checks
TYPE	box2d
TYPE	box2df
TYPE	box3d
TYPE	box3d_extent
TYPE	chip
TYPE	geography
TYPE	geometry
TYPE	geometry_dump
TYPE	geomval
TYPE	getfaceedges_returntype
TYPE	gidx
TYPE	histogram
TYPE	histogram2d
TYPE	pgis_abs
TYPE	quantile
TYPE	raster
TYPE	rastexpr
TYPE	reclassarg
TYPE	spheroid
TYPE	summarystats
TYPE	topogeometry
TYPE	validatetopology_returntype
TYPE	valid_detail
TYPE	valuecount
TYPE	wktgeomval
VIEW	geography_columns
VIEW	geometry_columns
VIEW	raster_columns
VIEW	raster_overviews
