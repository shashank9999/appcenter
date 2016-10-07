namespace AppCenter {
    public abstract class AbstractAppContainer : Gtk.Grid {
        public AppCenterCore.Package package;

        protected Gtk.Image image;
        protected Gtk.Label package_name;
        protected Gtk.Label package_summary;

        // The action button covers Install and Update
        protected Widgets.AppActionButton action_button;
        protected Widgets.AppActionButton uninstall_button;
        protected Gtk.ProgressBar progress_bar;
        protected Gtk.Button cancel_button;
        protected Gtk.SizeGroup action_button_group;
        protected Gtk.Stack action_stack;
        protected bool show_uninstall;

        public bool is_os_updates {
            get {
                return package.is_os_updates;
            }
        }

        public bool update_available {
            get {
                return package.update_available || package.is_updating;
            }
        }

        public bool is_updating {
            get {
                return package.is_updating;
            }
        }

        public string name_label {
            get {
                return package_name.label;
            }
        }

        public bool action_sensitive {
            set {
                action_button.sensitive = value;
            }
        }

        construct {
            image = new Gtk.Image ();

            progress_bar = new Gtk.ProgressBar ();
            progress_bar.show_text = true;
            progress_bar.valign = Gtk.Align.CENTER;
            /* Request a width large enough for the longest text to stop width of
             * progress bar jumping around */
            progress_bar.width_request = 350;
            progress_bar.no_show_all = true;
            progress_bar.hide ();

            action_button_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.BOTH);

            cancel_button = new Widgets.AppActionButton (_("Cancel"));
            cancel_button.clicked.connect (() => action_cancelled ());

            action_button = new Widgets.AppActionButton (_("Install"));
            action_button.clicked.connect (() => action_clicked.begin ());

            uninstall_button = new Widgets.AppActionButton (_("Uninstall"));
            uninstall_button.clicked.connect (() => uninstall_clicked.begin ());

            var button_grid = new Gtk.Grid ();
            button_grid.halign = Gtk.Align.END;
            button_grid.valign = Gtk.Align.CENTER;
            button_grid.orientation = Gtk.Orientation.HORIZONTAL;
            button_grid.add (uninstall_button);
            button_grid.add (action_button);

            var progress_grid = new Gtk.Grid ();
            progress_grid.valign = Gtk.Align.CENTER;
            progress_grid.column_spacing = 12;
            progress_grid.attach (progress_bar, 0, 0, 1, 1);
            progress_grid.attach (cancel_button, 1, 0, 1, 1);

            action_stack = new Gtk.Stack ();
            action_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            action_stack.show_all ();

            action_button_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
            action_button_group.add_widget (action_button);
            action_button_group.add_widget (uninstall_button);
            action_button_group.add_widget (cancel_button);

            action_stack.add_named (button_grid, "buttons");
            action_stack.add_named (progress_grid, "progress");
        }

        protected virtual void set_up_package (uint icon_size = 48) {
            package_name.label = package.get_name ();
            package_summary.label = package.get_summary ();
            package_summary.ellipsize = Pango.EllipsizeMode.END;
            image.gicon = package.get_icon (icon_size);

            package.notify["state"].connect (update_state);

            package.change_information.bind_property ("can-cancel", cancel_button, "sensitive", GLib.BindingFlags.SYNC_CREATE);
            package.change_information.progress_changed.connect (update_progress);
            package.change_information.status_changed.connect (update_progress_status);

            update_progress_status ();
            update_progress ();
            update_state ();
        }

        protected virtual void update_state () {
            update_action ();
        }

        protected void update_action (bool show_uninstall = true) {
            uninstall_button.no_show_all = true;
            uninstall_button.hide ();
            progress_bar.no_show_all = true;
            progress_bar.hide ();
            action_stack.no_show_all = false;
            action_stack.show_all ();
            action_stack.set_visible_child_name ("buttons");

            switch (package.state) {
                case AppCenterCore.Package.State.NOT_INSTALLED:
                    action_button.label = _("Install");
                    action_button.no_show_all = false;
                    action_button.show ();
                    break;

                case AppCenterCore.Package.State.INSTALLED:
                    if (show_uninstall) {
                        /* Uninstall button will show */
                        action_button.label = "Not visible";
                        action_button.no_show_all = true;
                        action_button.hide ();

                        if (!is_os_updates) {
                            uninstall_button.no_show_all = false;
                            uninstall_button.show_all ();
                        }
                    } else {
                        /* No Uninstall action in list view */
                        action_stack.no_show_all = true;
                        action_stack.hide ();
                    }

                    break;

                case AppCenterCore.Package.State.UPDATE_AVAILABLE:
                    action_button.label = _("Update");
                    break;

                case AppCenterCore.Package.State.INSTALLING:
                case AppCenterCore.Package.State.UPDATING:
                case AppCenterCore.Package.State.REMOVING:
                    progress_bar.no_show_all = false;
                    progress_bar.show ();
                    action_stack.set_visible_child_name ("progress");
                    break;

                default:
                    assert_not_reached ();
            }
        }

        protected void update_progress () {
             progress_bar.fraction = package.progress;
         }

        protected void update_progress_status () {
            progress_bar.text = package.get_progress_description ();
            /* Ensure progress bar shows complete to match status (lp:1606902) */
            if (package.changes_finished) {
                progress_bar.fraction = 1.0f;
                cancel_button.sensitive = false;
            }
        }

        private void action_cancelled () {
            package.action_cancellable.cancel ();
        }

        private async void action_clicked () {
             if (package.update_available) {
                 yield package.update ();
            } else if (yield package.install ()) {
                 // Add this app to the Installed Apps View
                 MainWindow.installed_view.add_app.begin (package);
                update_state ();
            }
        }

        private async void uninstall_clicked () {
            if (yield package.uninstall ()) {
                // Remove this app from the Installed Apps View
                MainWindow.installed_view.remove_app.begin (package);
                update_state ();
            }
        }
    }
}
