/*-
 * Copyright 2019 elementary, Inc. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: David Hewitt <davidmhewitt@gmail.com>
 */

public class AppCenterCore.FlatpakBackend : Backend, Object {
    private AsyncQueue<Job> jobs = new AsyncQueue<Job> ();
    private Thread<bool> worker_thread;

    private Gee.HashMap<string, Package> package_list;
    private AppStream.Pool appstream_pool;

    // This is OK as we're only using a single thread (PackageKit can only do one job at a time)
    // This would have to be done differently if there were multiple workers in the pool
    private bool thread_should_run = true;

    public bool working { get; private set; }

    private bool worker_func () {
        while (thread_should_run) {
            working = false;
            var job = jobs.pop ();
            working = true;
            switch (job.operation) {
                case Job.Type.REFRESH_CACHE:
                    refresh_cache_internal (job);
                    break;
                default:
                    assert_not_reached ();
            }
        }

        return true;
    }

    private FlatpakBackend () {
        worker_thread = new Thread<bool> ("flatpak-worker", worker_func);
        appstream_pool = new AppStream.Pool ();
        appstream_pool.set_cache_flags (AppStream.CacheFlags.NONE);
        package_list = new Gee.HashMap<string, Package> (null, null);

        refresh_cache.begin (null);
    }

    ~FlatpakBackend () {
        thread_should_run = false;
        worker_thread.join ();
    }

    private async Job launch_job (Job.Type type, JobArgs? args = null) {
        var job = new Job (type);
        job.args = args;

        SourceFunc callback = launch_job.callback;
        job.results_ready.connect (() => {
            Idle.add ((owned) callback);
        });

        jobs.push (job);
        yield;
        return job;
    }

    public async Gee.Collection<Package> get_installed_applications () {
        return new Gee.ArrayList<Package> ();
    }

    public Gee.Collection<Package> get_applications_for_category (AppStream.Category category) {
        unowned GLib.GenericArray<AppStream.Component> components = category.get_components ();
        if (components.length == 0) {
            var category_array = new GLib.GenericArray<AppStream.Category> ();
            category_array.add (category);
            AppStream.utils_sort_components_into_categories (appstream_pool.get_components (), category_array, true);
            components = category.get_components ();
        }

        var apps = new Gee.TreeSet<AppCenterCore.Package> ();
        components.foreach ((comp) => {
            var package = get_package_for_component_id (comp.get_id ());
            if (package != null) {
                apps.add (package);
            }
        });

        return apps;
    }

    public Gee.Collection<Package> search_applications (string query, AppStream.Category? category) {
        var apps = new Gee.TreeSet<AppCenterCore.Package> ();
        GLib.GenericArray<weak AppStream.Component> comps = appstream_pool.search (query);
        if (category == null) {
            message ("search: %s", query);
            comps.foreach ((comp) => {
                var package = get_package_for_component_id (comp.get_id ());
                if (package != null) {
                    apps.add (package);
                }
            });
        } else {
            var cat_packages = get_applications_for_category (category);
            comps.foreach ((comp) => {
                var package = get_package_for_component_id (comp.get_id ());
                if (package != null && package in cat_packages) {
                    apps.add (package);
                }
            });
        }

        return apps;
    }

    public Gee.Collection<Package> search_applications_mime (string query) {
        return new Gee.ArrayList<Package> ();
    }

    public Package? get_package_for_component_id (string id) {
        foreach (var package in package_list.values) {
            if (package.component.id == id) {
                return package;
            } else if (package.component.id == id + ".desktop") {
                return package;
            }
        }

        return null;
    }

    public Package? get_package_for_desktop_id (string id) {
        return null;
    }

    public Gee.Collection<Package> get_packages_by_author (string author, int max) {
        return new Gee.ArrayList<Package> ();
    }

    public async uint64 get_download_size (Package package, Cancellable? cancellable) throws GLib.Error {
        return 0;
    }

    public async bool is_package_installed (Package package) throws GLib.Error {
        return false;
    }

    public async PackageDetails get_package_details (Package package) throws GLib.Error {
        message ("get_package_details");
        return new PackageDetails ();
    }

    private void refresh_cache_internal (Job job) {
        var args = (RefreshCacheArgs)job.args;
        var cancellable = args.cancellable;

        appstream_pool.clear_metadata_locations ();

        var dest_folder_path = Path.build_filename (
            Environment.get_user_cache_dir (),
            "io.elementary.appcenter",
            "flatpak-metadata"
        );

        var dest_folder = File.new_for_path (dest_folder_path);
        if (!dest_folder.query_exists ()) {
            dest_folder.make_directory_with_parents ();
        }

        delete_folder_contents (dest_folder, cancellable);

        var installations = Flatpak.get_system_installations ();
        for (int i = 0; i < installations.length; i++) {
            unowned Flatpak.Installation installation = installations[i];

            var xremotes = installation.list_remotes ();
            for (int j = 0; j < xremotes.length; j++) {
                bool cache_refresh_needed = false;

                unowned Flatpak.Remote remote = xremotes[j];
                if (remote.get_disabled ()) {
                    continue;
                }

                unowned string origin_name = remote.get_name ();
                message ("Found remote: %s", origin_name);

                var timestamp_file = remote.get_appstream_timestamp (null);
                if (!timestamp_file.query_exists ()) {
                    cache_refresh_needed = true;
                } else {
                    var age = Utils.get_file_age (timestamp_file);
                    message ("Appstream age: %u", age);
                    if (age > 600) {
                        message ("Appstream cache older than 10 mins, refreshing");
                        cache_refresh_needed = true;
                    }
                }

                if (cache_refresh_needed) {
                    message ("Updating remote");
                    bool success = false;
                    try {
                        success = installation.update_remote_sync (remote.get_name ());
                    } catch (Error e) {
                        warning ("Unable to update remote: %s", e.message);
                    }
                    message ("Remote updated: %s", success.to_string ());

                    message ("Updating appstream data");
                    success = false;
                    try {
                        success = installation.update_appstream_sync (remote.get_name (), null, null, cancellable);
                    } catch (Error e) {
                        warning ("Unable to update appstream: %s", e.message);
                    }

                    message ("Appstream updated: %s", success.to_string ());
                }

                var metadata_location = remote.get_appstream_dir (null).get_path ();
                var metadata_folder_file = File.new_for_path (metadata_location);

                var metadata_path = Path.build_filename (metadata_location, "appstream.xml.gz");
                var metadata_file = File.new_for_path (metadata_path);

                if (metadata_file.query_exists ()) {
                    var dest_file = dest_folder.get_child (origin_name + ".xml.gz");

                    perform_xml_fixups (origin_name, metadata_file, dest_file);

                    var local_icons_path = dest_folder.get_child ("icons");
                    if (!local_icons_path.query_exists ()) {
                        local_icons_path.make_directory ();
                    }

                    var remote_icons_folder = metadata_folder_file.get_child ("icons");
                    if (!remote_icons_folder.query_exists ()) {
                        continue;
                    }

                    if (remote_icons_folder.get_child (origin_name).query_exists ()) {
                        local_icons_path = local_icons_path.get_child (origin_name);
                        local_icons_path.make_symbolic_link (remote_icons_folder.get_child (origin_name).get_path ());
                    } else {
                        local_icons_path = local_icons_path.get_child (origin_name);
                        local_icons_path.make_symbolic_link (remote_icons_folder.get_path ());
                    }
                } else {
                    continue;
                }
            }
        }

        appstream_pool.add_metadata_location (dest_folder_path);
        message ("Loading pool");
        try {
            appstream_pool.load ();
        } catch (Error e) {
            warning (e.message);
        } finally {
            var comp_validator = ComponentValidator.get_default ();
            appstream_pool.get_components ().foreach ((comp) => {
                if (!comp_validator.validate (comp)) {
                    return;
                }

                var bundle = comp.get_bundle (AppStream.BundleKind.FLATPAK);
                if (bundle != null) {
                    var package = new AppCenterCore.Package (this, comp);
                    var key = "%s/%s".printf (comp.get_origin (), bundle.get_id ());
                    package_list[key] = package;
                }
            });
        }

        job.result = Value (typeof (bool));
        job.result.set_boolean (true);
        job.results_ready ();
    }

    private void delete_folder_contents (File folder, Cancellable? cancellable = null) {
        var enumerator = folder.enumerate_children (
            "standard::*",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
            cancellable
        );

        FileInfo info = null;
        while ((info = enumerator.next_file (cancellable)) != null) {
            if (info.get_file_type () != FileType.DIRECTORY) {
                var child = folder.resolve_relative_path (info.get_name ());
                message ("Deleting %s", child.get_path ());
                child.delete ();
            } else {
                var child = folder.resolve_relative_path (info.get_name ());
                delete_folder_contents (child, cancellable);
                child.delete ();
            }
        }
    }

    private void perform_xml_fixups (string origin_name, File src_file, File dest_file) {
        var path = src_file.get_path ();
        Xml.Doc* doc = Xml.Parser.parse_file (path);
        if (doc == null) {
            warning ("Appstream XML file %s not found or permissions missing", path);
            return;
        }

        Xml.Node* root = doc->get_root_element ();
        if (root == null) {
            delete doc;
            warning ("The xml file '%s' is empty", path);
            return;
        }

        if (root->name != "components") {
            delete doc;
            warning ("The root node of %s isn't 'components', valid appstream file?", path);
            return;
        }

        Xml.Attr* origin_attr = root->has_prop ("origin");
        if (origin_attr == null) {
            delete doc;
            warning ("The root node of %s doesn't have an origin attribute, valid appstream file?", path);
            return;
        }

        root->set_prop ("origin", origin_name);

        doc->set_compress_mode (7);
        doc->save_file (dest_file.get_path ());
        delete doc;
    }

    public async bool refresh_cache (Cancellable cancellable) throws GLib.Error {
        var job_args = new RefreshCacheArgs ();
        job_args.cancellable = cancellable;

        var job = yield launch_job (Job.Type.REFRESH_CACHE, job_args);
        if (job.error != null) {
            throw job.error;
        }

        return job.result.get_boolean ();
    }

    public async bool install_package (Package package, owned Pk.ProgressCallback cb, Cancellable cancellable) throws GLib.Error {
        return false;
    }

    public async bool remove_package (Package package, owned Pk.ProgressCallback cb, Cancellable cancellable) throws GLib.Error {
        return false;
    }

    public async bool update_package (Package package, owned Pk.ProgressCallback cb, Cancellable cancellable) throws GLib.Error {
        return false;
    }

    private static GLib.Once<FlatpakBackend> instance;
    public static unowned FlatpakBackend get_default () {
        return instance.once (() => { return new FlatpakBackend (); });
    }
}
