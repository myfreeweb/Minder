/*
* Copyright (c) 2018 (https://github.com/phase1geo/Minder)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 2 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*
* Authored by: Trevor Williams <phase1geo@gmail.com>
*/

using Gtk;
using GLib;
using Gdk;
using Cairo;

public class DrawArea : Gtk.DrawingArea {

  private const Gtk.TargetEntry[] DRAG_TARGETS = {
    {"text/uri-list", 0, 0}
  };

  private double           _press_x;
  private double           _press_y;
  private double           _origin_x;
  private double           _origin_y;
  private double           _scale_factor;
  private double           _store_origin_x;
  private double           _store_origin_y;
  private double           _store_scale_factor;
  private bool             _pressed    = false;
  private EventType        _press_type = EventType.NOTHING;
  private bool             _resize     = false;
  private bool             _motion     = false;
  private Node?            _current_node;
  private bool             _current_new = false;
  private Array<Node>      _nodes;
  private Theme            _theme;
  private Layout           _layout;
  private string           _orig_name;
  private NodeSide         _orig_side;
  private Array<NodeInfo?> _orig_info;
  private int              _orig_width;
  private Node?            _attach_node  = null;
  private DrawAreaMenu     _popup_menu;
  private uint?            _auto_save_id = null;
  private ImageEditor      _editor;
  private IMContextSimple  _im_context;

  public UndoBuffer   undo_buffer    { set; get; }
  public Themes       themes         { set; get; default = new Themes(); }
  public Layouts      layouts        { set; get; default = new Layouts(); }
  public Animator     animator       { set; get; }
  public Node?        node_clipboard { set; get; default = null; }
  public ImageManager image_manager  { set; get; default = new ImageManager(); }

  public double origin_x {
    set {
      _store_origin_x = _origin_x = value;
    }
    get {
      return( _origin_x );
    }
  }
  public double origin_y {
    set {
      _store_origin_y = _origin_y = value;
    }
    get {
      return( _origin_y );
    }
  }
  public double sfactor {
    set {
      _store_scale_factor = _scale_factor = value;
    }
    get {
      return( _scale_factor );
    }
  }

  public signal void changed();
  public signal void node_changed();
  public signal void theme_changed();
  public signal void scale_changed( double scale );
  public signal void show_properties( string? tab, bool grab_note );
  public signal void loaded();

  /* Default constructor */
  public DrawArea() {

    /* Create the array of root nodes in the map */
    _nodes = new Array<Node>();

    /* Allocate memory for the animator */
    animator = new Animator( this );

    /* Allocate memory for the undo buffer */
    undo_buffer = new UndoBuffer( this );

    /* Allocate the image editor popover */
    _editor = new ImageEditor( this );
    _editor.changed.connect( current_image_edited );

    /* Create the popup menu */
    _popup_menu = new DrawAreaMenu( this );

    /* Create the node information array */
    _orig_info = new Array<NodeInfo?>();

    /* Set the theme to the default theme */
    set_theme( "Default" );
    set_layout( _( "Horizontal" ) );

    /* Add event listeners */
    this.draw.connect( on_draw );
    this.button_press_event.connect( on_press );
    this.motion_notify_event.connect( on_motion );
    this.button_release_event.connect( on_release );
    this.key_press_event.connect( on_keypress );
    this.scroll_event.connect( on_scroll );

    /* Make sure the above events are listened for */
    this.add_events(
      EventMask.BUTTON_PRESS_MASK |
      EventMask.BUTTON_RELEASE_MASK |
      EventMask.BUTTON1_MOTION_MASK |
      EventMask.POINTER_MOTION_MASK |
      EventMask.KEY_PRESS_MASK |
      EventMask.SMOOTH_SCROLL_MASK |
      EventMask.STRUCTURE_MASK
    );

    /* Set ourselves up to be a drag target */
    Gtk.drag_dest_set( this, DestDefaults.MOTION | DestDefaults.DROP, DRAG_TARGETS, Gdk.DragAction.COPY );

    this.drag_motion.connect( handle_drag_motion );
    this.drag_data_received.connect( handle_drag_data_received );

    /*
     Make sure that the images are cleaned up when the user exits the application or we received
     a terminate signal.
    */
    this.destroy.connect(() => {
      image_manager.cleanup();
    });

    /*
    TBD - This code does not compile
    Posix.sighandler_t? t = this.handle_sigterm;
    Posix.@signal( Posix.Signal.TERM, t );
    */

    /* Make sure the drawing area can receive keyboard focus */
    this.can_focus = true;

    /*
     Make sure that we add a CSS class name to ourselves so we can color
     our background with the theme.
    */
    get_style_context().add_class( "canvas" );

    /* Handle special character input */
    _im_context = new IMContextSimple();
    _im_context.commit.connect( handle_printable );

  }

  /* Called to handle a sigterm signal to the application */
  public void handle_sigterm( int s ) {
    image_manager.cleanup();
  }

  /* Returns the name of the currently selected theme */
  public string get_theme_name() {
    return( _theme.name );
  }

  /* Returns the current theme */
  public Theme get_theme() {
    return( _theme );
  }

  /* Sets the theme to the given value */
  public void set_theme( string name ) {
    Theme? orig_theme = _theme;
    _theme = themes.get_theme( name );
    StyleContext.add_provider_for_screen(
      Screen.get_default(),
      _theme.get_css_provider(),
      STYLE_PROVIDER_PRIORITY_APPLICATION
    );
    if( orig_theme != null ) {
      map_theme_colors( orig_theme );
    }
    theme_changed();
    queue_draw();
  }

  /* Updates all nodes with the new theme colors */
  private void map_theme_colors( Theme old_theme ) {
    for( int i=0; i<_nodes.length; i++ ) {
      _nodes.index( i ).map_theme_colors( old_theme, _theme );
    }
  }

  /* Returns the name of the currently selected theme */
  public string get_layout_name() {
    return( _layout.name );
  }

  /* Sets the layout to the given value */
  public void set_layout( string name, bool undoable = true ) {
    var new_layout = layouts.get_layout( name );
    if( _layout == null ) {
      _layout = new_layout;
    } else {
      if( undoable ) {
        undo_buffer.add_item( new UndoNodeLayout( _layout, new_layout ) );
      }
      var old_balanceable = _layout.balanceable;
      animator.add_nodes( "set layout" );
      _layout = new_layout;
      for( int i=0; i<_nodes.length; i++ ) {
        _layout.initialize( _nodes.index( i ) );
      }
      if( !old_balanceable && _layout.balanceable ) {
        balance_nodes( false );
      } else {
        animator.animate();
      }
    }
  }

  /* Returns the list of nodes */
  public Array<Node> get_nodes() {
    return( _nodes );
  }

  /* Sets the cursor of the drawing area */
  private void set_cursor( CursorType? type = null ) {

    var     win    = get_window();
    Cursor? cursor = win.get_cursor();

    if( type == null ) {
      win.set_cursor( null );
    } else if( (cursor == null) || (cursor.cursor_type != type) ) {
      win.set_cursor( new Cursor.for_display( get_display(), type ) );
    }

  }

  /* Loads the drawing area origin from the XML node */
  private void load_drawarea( Xml.Node* n ) {

    string? x = n->get_prop( "x" );
    if( x != null ) {
      origin_x = double.parse( x );
    }

    string? y = n->get_prop( "y" );
    if( y != null ) {
      origin_y = double.parse( y );
    }

    string? sf = n->get_prop( "scale" );
    if( sf != null ) {
      sfactor = double.parse( sf );
      scale_changed( sfactor );
    }

  }

  /* Loads the given theme from the list of available options */
  private void load_theme( Xml.Node* n ) {

    /* Get the theme */
    string? name = n->get_prop( "name" );
    if( name != null ) {
      _theme = themes.get_theme( name );
      StyleContext.add_provider_for_screen(
        Screen.get_default(),
        _theme.get_css_provider(),
        STYLE_PROVIDER_PRIORITY_APPLICATION
      );
      theme_changed();
    }

    /* Set the current theme index */
    string? index = n->get_prop( "index" );
    if( index != null ) {
      _theme.index = int.parse( index );
    }

  }

  /* Loads the given layout from the list of available options */
  private void load_layout( Xml.Node* n ) {
    string? name = n->get_prop( "name" );
    if( name != null ) {
      _layout = layouts.get_layout( name );
    }
  }

  /* Loads the contents of the data input stream */
  public void load( Xml.Node* n ) {

    /* Disable animations while we are loading */
    var animate = animator.enable;
    animator.enable = false;

    /* Clear the existing nodes */
    _nodes.remove_range( 0, _nodes.length );

    /* Load the contents of the file */
    for( Xml.Node* it = n->children; it != null; it = it->next ) {
      if( it->type == Xml.ElementType.ELEMENT_NODE ) {
        switch( it->name ) {
          case "theme"    :  load_theme( it );   break;
          case "layout"   :  load_layout( it );  break;
          case "drawarea" :  load_drawarea( it );  break;
          case "images"   :  image_manager.load( it );  break;
          case "nodes"    :
            for( Xml.Node* it2 = it->children; it2 != null; it2 = it2->next ) {
              if( (it2->type == Xml.ElementType.ELEMENT_NODE) && (it2->name == "node") ) {
                var node = new Node( this, _layout );
                node.load( this, it2, _layout );
                _nodes.append_val( node );
              }
            }
            break;
        }
      }
    }

    queue_draw();

    /* Indicate to anyone listening that we have loaded a new file */
    loaded();

    /* Reset the animator enable */
    animator.enable = animate;

  }

  /* Saves the contents of the drawing area to the data output stream */
  public bool save( Xml.Node* parent ) {

    Xml.Node* theme = new Xml.Node( null, "theme" );
    theme->new_prop( "name", _theme.name );
    theme->new_prop( "index", _theme.index.to_string() );
    parent->add_child( theme );

    Xml.Node* layout = new Xml.Node( null, "layout" );
    layout->new_prop( "name", _layout.name );
    parent->add_child( layout );

    Xml.Node* origin = new Xml.Node( null, "drawarea" );
    origin->new_prop( "x", _store_origin_x.to_string() );
    origin->new_prop( "y", _store_origin_y.to_string() );
    origin->new_prop( "scale", _store_scale_factor.to_string() );
    parent->add_child( origin );

    Xml.Node* images = new Xml.Node( null, "images" );
    image_manager.save( images );
    parent->add_child( images );

    Xml.Node* nodes = new Xml.Node( null, "nodes" );
    for( int i=0; i<_nodes.length; i++ ) {
      _nodes.index( i ).save( nodes );
    }
    parent->add_child( nodes );

    return( true );

  }

  /* Imports the OPML data, creating a mind map */
  public void import_opml( Xml.Node* n, ref Array<int>? expand_state) {

    int node_id = 1;

    /* Clear the existing nodes */
    _nodes.remove_range( 0, _nodes.length );

    /* Load the contents of the file */
    for( Xml.Node* it = n->children; it != null; it = it->next ) {
      if( it->type == Xml.ElementType.ELEMENT_NODE ) {
        if( it->name == "outline") {
          var root = new Node( this, _layout );
          root.import_opml( this, it, node_id, ref expand_state, _theme, _layout );
          _nodes.append_val( root );
        }
      }
    }

  }

  /* Exports all of the nodes in OPML format */
  public void export_opml( Xml.Node* parent, out string expand_state ) {
    Array<int> estate  = new Array<int>();
    int        node_id = 1;
    for( int i=0; i<_nodes.length; i++ ) {
      _nodes.index( i ).export_opml( parent, ref node_id, ref estate );
    }
    expand_state = "";
    for( int i=0; i<estate.length; i++ ) {
      if( i > 0 ) {
        expand_state += ",";
      }
      expand_state += estate.index( i ).to_string();
    }
  }

  /* Initializes the canvas to prepare it for a document that will be loaded */
  public void initialize_for_open() {

    /* Clear the list of existing nodes */
    _nodes.remove_range( 0, _nodes.length );

    /* Clear the undo buffer */
    undo_buffer.clear();

    /* Reset the node ID generator */
    Node.reset();

    /* Initialize variables */
    origin_x       = 0.0;
    origin_y       = 0.0;
    sfactor        = 1.0;
    node_clipboard = null;
    _pressed       = false;
    _press_type    = EventType.NOTHING;
    _motion        = false;
    _attach_node   = null;
    _orig_name     = "";
    _current_new   = false;

    set_current_node( null );

    queue_draw();

  }

  /* Initialize the empty drawing area with a node */
  public void initialize_for_new() {

    /* Clear the list of existing nodes */
    _nodes.remove_range( 0, _nodes.length );

    /* Clear the undo buffer */
    undo_buffer.clear();

    /* Reset the node ID generator */
    Node.reset();

    /* Initialize variables */
    origin_x       = 0.0;
    origin_y       = 0.0;
    sfactor        = 1.0;
    node_clipboard = null;
    _pressed       = false;
    _press_type    = EventType.NOTHING;
    _motion        = false;
    _attach_node   = null;
    _current_new   = false;

    /* Create the main idea node */
    var n = new Node.with_name( this, _("Main Idea"), _layout );

    /* Set the node information */
    n.posx = (get_allocated_width()  / 2) - 30;
    n.posy = (get_allocated_height() / 2) - 10;

    _layout.handle_update_by_edit( n );

    _nodes.append_val( n );
    _orig_name    = "";

    /* Make this initial node the current node */
    set_current_node( n );
    n.mode = NodeMode.EDITABLE;

    /* Redraw the canvas */
    queue_draw();

  }

  /* Returns the current node */
  public Node? get_current_node() {
    return( _current_node );
  }

  /* Returns the current layout */
  public Layout get_layout() {
    return( _layout );
  }

  /*
   Populates the list of matches with any nodes that match the given string
   pattern.
  */
  public void get_match_items( string pattern, bool[] search_opts, ref Gtk.ListStore matches ) {
    for( int i=0; i<_nodes.length; i++ ) {
      _nodes.index( i ).get_match_items( pattern, search_opts, ref matches );
    }
  }

  /* Sets the current node to the given node */
  public void set_current_node( Node? n ) {
    if( n == null ) {
      _current_node = n;
      node_changed();
    } else if( _current_node == n ) {
      _current_node.mode = NodeMode.CURRENT;
    } else {
      if( _current_node != null ) {
        _current_node.mode = NodeMode.NONE;
      }
      if( (n.parent != null) && n.parent.folded ) {
        var last = n.reveal( _layout );
        undo_buffer.add_item( new UndoNodeReveal( this, n, last ) );
      }
      _current_node      = n;
      _current_node.mode = NodeMode.CURRENT;
      node_changed();
    }
  }

  /* Toggles the value of the specified node, if possible */
  public void toggle_task( Node n ) {
    undo_buffer.add_item( new UndoNodeTask( n, true, !n.task_done() ) );
    n.toggle_task_done();
    queue_draw();
    changed();
  }

  /* Toggles the fold for the given node */
  public void toggle_fold( Node n ) {
    bool fold = !n.folded;
    undo_buffer.add_item( new UndoNodeFold( n, fold ) );
    n.folded = fold;
    _layout.handle_update_by_fold( n );
    queue_draw();
    changed();
  }

  /*
   Changes the current node's name to the given name.  Updates the layout,
   adds the undo item, and redraws the canvas.
  */
  public void change_current_name( string name ) {
    if( (_current_node != null) && (_current_node.name != name) ) {
      string orig_name = _current_node.name;
      _current_node.name = name;
      _layout.handle_update_by_edit( _current_node );
      if( !_current_new ) {
        undo_buffer.add_item( new UndoNodeName( _current_node, orig_name ) );
      }
      queue_draw();
      changed();
    }
  }

  /*
   Changes the current node's task to the given values.  Updates the layout,
   adds the undo item, and redraws the canvas.
  */
  public void change_current_task( bool enable, bool done ) {
    if( _current_node != null ) {
      undo_buffer.add_item( new UndoNodeTask( _current_node, enable, done ) );
      _current_node.enable_task( enable );
      _current_node.set_task_done( done );
      _layout.handle_update_by_edit( _current_node );
      queue_draw();
      changed();
    }
  }

  /*
   Changes the current node's folded state to the given value.  Updates the
   layout, adds the undo item and redraws the canvas.
  */
  public void change_current_fold( bool folded ) {
    if( _current_node != null ) {
      undo_buffer.add_item( new UndoNodeFold( _current_node, folded ) );
      _current_node.folded = folded;
      _layout.handle_update_by_fold( _current_node );
      queue_draw();
      changed();
    }
  }

  /*
   Changes the current node's folded state to the given value.  Updates the
   layout, adds the undo item and redraws the canvas.
  */
  public void change_current_note( string note ) {
    if( _current_node != null ) {
      string orig_note = _current_node.note;
      _current_node.note = note;
      if( (note.length == 0) != (orig_note.length == 0) ) {
        _layout.handle_update_by_edit( _current_node );
        queue_draw();
      }
      auto_save();
    }
  }

  /*
   Adds an image to the current node by allowing the user to select an image file
   from the file system and, optionally, editing the image prior to assigning it
   to a node.  Updates the layout, adds the undo item and redraws the canvas.
   item and redraws the canvas.
  */
  public void add_current_image() {
    if( _current_node != null ) {
      if( _current_node.get_image() == null ) {
        var parent = (Gtk.Window)get_toplevel();
        var id     = image_manager.choose_image( parent );
        if( id != -1 ) {
          var max_width = _current_node.max_width();
          _current_node.set_image( image_manager, new NodeImage( image_manager, id, max_width ) );
          if( _current_node.get_image() != null ) {
            undo_buffer.add_item( new UndoNodeImage( _current_node, null ) );
            _layout.handle_update_by_edit( _current_node );
            queue_draw();
            node_changed();
            auto_save();
          }
        }
      }
    }
  }

  /*
   Deletes the image from the current node.  Updates the layout, adds the undo
   item and redraws the canvas.
  */
  public void delete_current_image() {
    if( _current_node != null ) {
      NodeImage? orig_image = _current_node.get_image();
      if( orig_image != null ) {
        _current_node.set_image( image_manager, null );
        undo_buffer.add_item( new UndoNodeImage( _current_node, orig_image ) );
        _layout.handle_update_by_edit( _current_node );
        queue_draw();
        node_changed();
        auto_save();
      }
    }
  }

  /*
   Causes the current node's image to be edited.
  */
  public void edit_current_image() {
    if( _current_node != null ) {
      if( _current_node.get_image() != null ) {
        _editor.edit_image( image_manager, _current_node, _current_node.posx, _current_node.posy );
      }
    }
  }

  /* Called whenever the current node's image is changed */
  private void current_image_edited( NodeImage? orig_image ) {
    undo_buffer.add_item( new UndoNodeImage( _current_node, orig_image ) );
    _layout.handle_update_by_edit( _current_node );
    queue_draw();
    node_changed();
    auto_save();
  }

  /*
   Changes the current node's link color and propagates that color to all
   descendants.
  */
  public void change_current_link_color( RGBA color ) {
    if( _current_node != null ) {
      RGBA orig_color = _current_node.link_color;
      if( orig_color != color ) {
        _current_node.link_color = color;
        undo_buffer.add_item( new UndoNodeLinkColor( _current_node, orig_color ) );
        queue_draw();
        changed();
      }
    }
  }

  /*
   Sets the current node pointer to the node that is within the given coordinates.
   Returns true if we sucessfully set current_node to a valid node and made it
   selected.
  */
  private bool set_current_node_at_position( double x, double y, EventButton e ) {
    for( int i=0; i<_nodes.length; i++ ) {
      Node match = _nodes.index( i ).contains( x, y, null );
      if( match != null ) {
        if( match.is_within_task( x, y ) ) {
          toggle_task( match );
          node_changed();
          return( false );
        } else if( match.is_within_fold( x, y ) ) {
          toggle_fold( match );
          node_changed();
          return( false );
        } else if( match.is_within_resizer( x, y ) ) {
          _resize     = true;
          _orig_width = match.max_width();
          return( true );
        }
        _orig_side = match.side;
        _orig_info.remove_range( 0, _orig_info.length );
        match.get_node_info( ref _orig_info );
        if( match == _current_node ) {
          if( is_mode_edit() ) {
            switch( e.type ) {
              case EventType.BUTTON_PRESS :         match.set_cursor_at_char( x, y, false );  break;
              case EventType.DOUBLE_BUTTON_PRESS :  match.set_cursor_at_word( x, y, false );  break;
              case EventType.TRIPLE_BUTTON_PRESS :  match.set_cursor_all( false );            break;
            }
          } else if( e.type == EventType.DOUBLE_BUTTON_PRESS ) {
            if( _current_node.is_within_image( x, y ) ) {
              edit_current_image();
              return( false );
            } else {
              _current_node.mode = NodeMode.EDITABLE;
            }
          }
          return( true );
        } else {
          _current_new = false;
          if( _current_node != null ) {
            _current_node.mode = NodeMode.NONE;
          }
          _current_node = match;
          if( match.mode == NodeMode.NONE ) {
            match.mode = NodeMode.CURRENT;
            node_changed();
            return( true );
          }
        }
        return( false );
      }
    }
    if( _current_node != null ) {
      _current_node.mode = NodeMode.NONE;
    }
    _current_node = null;
    node_changed();
    return( true );
  }

  /* Returns the supported scale points */
  public double[] get_scale_marks() {
    double[] marks = {10, 25, 50, 75, 100, 150, 200, 250, 300, 350, 400};
    return( marks );
  }

  /* Returns a properly scaled version of the given value */
  private double scale_value( double val ) {
    return( val / sfactor );
  }

  /*
   Sets the scaling factor for the drawing area, causing the center pixel
   to remain in the center and forces a redraw.
  */
  public void set_scaling_factor( double sf ) {
    if( sfactor != sf ) {
      int    width  = get_allocated_width()  / 2;
      int    height = get_allocated_height() / 2;
      double diff_x = (width  / sfactor) - (width  / sf);
      double diff_y = (height / sfactor) - (height / sf);
      move_origin( diff_x, diff_y );
      sfactor = sf;
      scale_changed( sfactor );
    }
  }

  /* Returns the scaling factor based on the given width and height */
  private double get_scaling_factor( double width, double height ) {
    double w  = get_allocated_width() / width;
    double h  = get_allocated_height() / height;
    double sf = (w < h) ? w : h;
    return( (sf > 4) ? 4 : sf );
  }

  /*
   Zooms into the image by one scale mark.  Returns true if the zoom was successful;
   otherwise, returns false.
  */
  public bool zoom_in() {
    var value = sfactor * 100;
    var marks = get_scale_marks();
    if( value < marks[0] ) {
      value = marks[0];
    }
    foreach (double mark in marks) {
      if( value < mark ) {
        animator.add_scale( "zoom in" );
        set_scaling_factor( mark / 100 );
        animator.animate();
        return( true );
      }
    }
    return( false );
  }

  /*
   Zooms out of the image by one scale mark.  Returns true if the zoom was successful;
   otherwise, returns false.
  */
  public bool zoom_out() {
    double value = sfactor * 100;
    var    marks = get_scale_marks();
    double last  = marks[0];
    if( value > marks[marks.length-1] ) {
      value = marks[marks.length-1];
    }
    foreach (double mark in marks) {
      if( value <= mark ) {
        animator.add_scale( "zoom out" );
        set_scaling_factor( last / 100 );
        animator.animate();
        return( true );
      }
      last = mark;
    }
    return( false );
  }

  /*
   Positions the given box in the canvas based on the provided
   x and y positions (values between 0 and 1).
  */
  private void position_box( double x, double y, double w, double h, double xpos, double ypos ) {
    double ccx = scale_value( get_allocated_width()  * xpos );
    double ccy = scale_value( get_allocated_height() * ypos );
    double ncx = x + (w * xpos);
    double ncy = y + (h * ypos);
    move_origin( (ncx - ccx), (ncy - ccy) );
  }

  /*
   Returns the scaling factor required to display the currently selected node.
   If no node is currently selected, returns a value of 0.
  */
  public void zoom_to_selected() {
    double x, y, w, h;
    if( _current_node == null ) return;
    animator.add_scale( "zoom to selected" );
    _layout.bbox( _current_node, -1, out x, out y, out w, out h );
    position_box( x, y, w, h, 0.5, 0.5 );
    set_scaling_factor( get_scaling_factor( w, h ) );
    animator.animate();
  }

  public void document_rectangle( out double x, out double y, out double width, out double height ) {

    double x1 =  10000000;
    double y1 =  10000000;
    double x2 = -10000000;
    double y2 = -10000000;

    /* Calculate the overall size of the map */
    for( int i=0; i<_nodes.length; i++ ) {
      double nx, ny, nw, nh;
      _layout.bbox( _nodes.index( i ), -1, out nx, out ny, out nw, out nh );
      x1 = (x1 < nx) ? x1 : nx;
      y1 = (y1 < ny) ? y1 : ny;
      x2 = (x2 < (nx + nw)) ? (nx + nw) : x2;
      y2 = (y2 < (ny + nh)) ? (ny + nh) : y2;
    }

    /* Set the outputs */
    x      = x1;
    y      = y1;
    width  = (x2 - x1);
    height = (y2 - y1);

  }

  /* Returns the scaling factor required to display all nodes */
  public void zoom_to_fit() {

    animator.add_scale( "zoom to fit" );

    /* Get the document rectangle */
    double x, y, w, h;
    document_rectangle( out x, out y, out w, out h );

    /* Center the map and scale it to fit */
    position_box( x, y, w, h, 0.5, 0.5 );
    set_scaling_factor( get_scaling_factor( w, h ) );

    /* Animate the scaling */
    animator.animate();

  }

  /* Centers the given node within the canvas by adjusting the origin */
  public void center_node( Node n ) {
    double x, y, w, h;
    n.bbox( out x, out y, out w, out h );
    animator.add_pan( "center node" );
    position_box( x, y, w, h, 0.5, 0.5 );
    animator.animate();
  }

  /* Centers the currently selected node */
  public void center_current_node() {
    if( _current_node != null ) {
      center_node( _current_node );
    }
  }

  /* Brings the given node into view in its entirety including the given amount of padding */
  public void see( double width_adjust = 0, double pad = 100.0 ) {

    if( _current_node == null ) return;

    double x, y, w, h;
    _current_node.bbox( out x, out y, out w, out h );

    double diff_x = 0;
    double diff_y = 0;
    double sw     = scale_value( get_allocated_width() + width_adjust );
    double sh     = scale_value( get_allocated_height() );

    if( (x - pad) < 0 ) {
      diff_x = (x - pad);
    } else if( (x + w) > sw ) {
      diff_x = (x + w + pad) - sw;
    }

    if( (y - pad) < 0 ) {
      diff_y = (y - pad);
    } else if( (y + h) > sh ) {
      diff_y = (y + h + pad) - sh;
    }

    if( (diff_x != 0) || (diff_y != 0) ) {
      animator.add_pan( "see" );
      move_origin( diff_x, diff_y );
      animator.animate();
    }

  }

  /* Returns the attachable node if one is found */
  private Node? attachable_node( double x, double y ) {
    for( int i=0; i<_nodes.length; i++ ) {
      Node tmp = _nodes.index( i ).contains( x, y, _current_node );
      if( (tmp != null) && (tmp != _current_node.parent) && !_current_node.contains_node( tmp ) ) {
        return( tmp );
      }
    }
    return( null );
  }

  /* Returns the droppable node if one is found */
  private Node? droppable_node( double x, double y ) {
    for( int i=0; i<_nodes.length; i++ ) {
      Node tmp = _nodes.index( i ).contains( x, y, null );
      if( tmp != null ) {
        return( tmp );
      }
    }
    return( null );
  }

  /* Returns the origin */
  public void get_origin( out double x, out double y ) {
    x = origin_x;
    y = origin_y;
  }

  /* Sets the origin to the given x and y coordinates */
  public void set_origin( double x, double y ) {
    move_origin( (x - origin_x), (y - origin_y) );
  }

  /* Checks to see if the boundary of the map never goes out of view */
  private bool out_of_bounds( double diff_x, double diff_y ) {

    double x, y, w, h;
    double aw = scale_value( get_allocated_width() );
    double ah = scale_value( get_allocated_height() );
    double s  = 40;

    document_rectangle( out x, out y, out w, out h );

    x -= diff_x;
    y -= diff_y;

    return( ((x + w) < s) || ((y + h) < s) || ((aw - x) < s) || ((ah - y) < s) );

  }

  /*
   Adjusts the x and y origins, panning all elements by the given amount.
   Important Note:  When the canvas is panned to the left (causing all
   nodes to be moved to the left, the origin_x value becomes a positive
   number.
  */
  public void move_origin( double diff_x, double diff_y ) {
    if( out_of_bounds( diff_x, diff_y ) ) {
      return;
    }
    origin_x += diff_x;
    origin_y += diff_y;
    for( int i=0; i<_nodes.length; i++ ) {
      _nodes.index( i ).pan( diff_x, diff_y );
    }
  }

  /* Draw the background from the stylesheet */
  public void draw_background( Context ctx ) {
    get_style_context().render_background( ctx, 0, 0, (get_allocated_width() / _scale_factor), (get_allocated_height() / _scale_factor) );
  }

  /* Draws all of the root node trees */
  public void draw_all( Context ctx ) {
    for( int i=0; i<_nodes.length; i++ ) {
      _nodes.index( i ).draw_all( ctx, _theme, _current_node, false, false );
    }
    /* Draw the current node on top of all others */
    if( (_current_node != null) && ((_current_node.parent == null) || !_current_node.parent.folded) ) {
      _current_node.draw_all( ctx, _theme, null, true, (_pressed && _motion && !_resize) );
    }
  }

  /* Draw the available nodes */
  public bool on_draw( Context ctx ) {
    if( _layout.default_text_height == 0 ) {
      var text = Pango.cairo_create_layout( ctx );
      int width, height;
      text.set_font_description( _layout.get_font_description() );
      text.set_text( "O", -1 );
      text.get_size( out width, out height );
      _layout.default_text_height = height / Pango.SCALE;
    }
    ctx.scale( sfactor, sfactor );
    draw_background( ctx );
    draw_all( ctx );
    return( false );
  }

  /* Handle button press event */
  private bool on_press( EventButton event ) {
    switch( event.button ) {
      case Gdk.BUTTON_PRIMARY :
        grab_focus();
        _press_x    = scale_value( event.x );
        _press_y    = scale_value( event.y );
        _pressed    = set_current_node_at_position( _press_x, _press_y, event );
        _press_type = event.type;
        _motion     = false;
        queue_draw();
        break;
      case Gdk.BUTTON_SECONDARY :
#if GTK322
        _popup_menu.popup_at_pointer( event );
#else
        _popup_menu.popup( null, null, null, event.button, event.time );
#endif
        break;
    }
    return( false );
  }

  /* Handle mouse motion */
  private bool on_motion( EventMotion event ) {
    if( _attach_node != null ) {
      _attach_node.mode = NodeMode.NONE;
      _attach_node      = null;
      queue_draw();
    }
    if( _pressed ) {
      if( _current_node != null ) {
        double diffx = scale_value( event.x ) - _press_x;
        double diffy = scale_value( event.y ) - _press_y;
        if( _current_node.mode == NodeMode.CURRENT ) {
          if( _resize ) {
            _current_node.resize( diffx, _layout );
          } else {
            Node attach_node = attachable_node( scale_value( event.x ), scale_value( event.y ) );
            if( attach_node != null ) {
              attach_node.mode = NodeMode.ATTACHABLE;
              _attach_node = attach_node;
            }
            _current_node.posx += diffx;
            _current_node.posy += diffy;
            _layout.set_side( _current_node );
          }
        } else {
          switch( _press_type ) {
            case EventType.BUTTON_PRESS        :  _current_node.set_cursor_at_char( scale_value( event.x ), scale_value( event.y ), true );  break;
            case EventType.DOUBLE_BUTTON_PRESS :  _current_node.set_cursor_at_word( scale_value( event.x ), scale_value( event.y ), true );  break;
          }
        }
        queue_draw();
      } else {
        double diff_x = _press_x - scale_value( event.x );
        double diff_y = _press_y - scale_value( event.y );
        move_origin( diff_x, diff_y );
        queue_draw();
      }
      _press_x = scale_value( event.x );
      _press_y = scale_value( event.y );
      _motion  = true;
      auto_save();
    } else {
      for( int i=0; i<_nodes.length; i++ ) {
        Node match = _nodes.index( i ).contains( event.x, event.y, null );
        if( match != null ) {
          if( get_tooltip_text() == null ) {
            if( match.is_within_task( event.x, event.y ) ) {
              set_cursor( CursorType.HAND1 );
              set_tooltip_text( _( "%0.3g%% complete" ).printf( match.task_completion_percentage() ) );
            } else if( match.is_within_note( event.x, event.y ) ) {
              set_tooltip_text( match.note );
            } else if( match.is_within_resizer( event.x, event.y ) ) {
              set_cursor( CursorType.SB_H_DOUBLE_ARROW );
            } else {
              set_cursor( null );
            }
          }
          return( false );
        }
      }
      if( get_tooltip_text() != null ) {
        set_tooltip_text( null );
      }
      set_cursor( null );
    }
    return( false );
  }

  /* Handle button release event */
  private bool on_release( EventButton event ) {
    _pressed = false;
    if( _motion ) {
      set_cursor( null );
    }
    if( _resize ) {
      _resize = false;
      undo_buffer.add_item( new UndoNodeResize( _current_node, _orig_width ) );
      return( false );
    }
    if( _current_node != null ) {
      if( _current_node.mode == NodeMode.CURRENT ) {

        /* If we are hovering over an attach node, perform the attachment */
        if( _attach_node != null ) {
          attach_current_node();

        /* If we are not in motion, set the cursor */
        } else if( !_motion ) {
          _current_node.set_cursor_all( false );
          _orig_name = _current_node.name;
          _current_node.move_cursor_to_end();

        /* If we are not a root node, move the node into the appropriate position */
        } else if( _current_node.parent != null ) {
          int orig_index = _current_node.index();
          animator.add_node( _current_node, "move to position" );
          _current_node.parent.move_to_position( _current_node, _orig_side, scale_value( event.x ), scale_value( event.y ), _layout );
          undo_buffer.add_item( new UndoNodeMove( _current_node, _orig_side, orig_index ) );
          animator.animate();

        /* Otherwise, redraw everything after the move */
        } else {
          queue_draw();
        }
      }
    }
    return( false );
  }

  /* Attaches the current node to the attach node */
  private void attach_current_node() {

    Node? orig_parent = null;
    int   orig_index  = -1;
    bool  isroot      = _current_node.is_root();

    /* Remove the current node from its current location */
    if( isroot ) {
      for( int i=0; i<_nodes.length; i++ ) {
        if( _nodes.index( i ) == _current_node ) {
          _nodes.remove_index( i );
          orig_index = i;
          break;
        }
      }
    } else {
      orig_parent = _current_node.parent;
      orig_index  = _current_node.index();
      _current_node.detach( _orig_side, _layout );
    }

    /* Attach the node */
    _current_node.attach( _attach_node, -1, _theme, _layout );
    _attach_node.mode = NodeMode.NONE;
    _attach_node      = null;

    /* Add the attachment information to the undo buffer */
    if( isroot ) {
      undo_buffer.add_item( new UndoNodeAttach.for_root( _current_node, orig_index, _orig_info ) );
    } else {
      undo_buffer.add_item( new UndoNodeAttach( _current_node, orig_parent, _orig_side, orig_index, _orig_info ) );
    }

    queue_draw();
    changed();
    node_changed();

  }

  /* Returns true if we are in some sort of edit mode */
  private bool is_mode_edit() {
    return( _current_node.mode == NodeMode.EDITABLE );
  }

  /* Returns true if we are in the selected mode */
  private bool is_mode_selected() {
    return( _current_node.mode == NodeMode.CURRENT );
  }

  /* If the specified node is not null, selects the node and makes it the current node */
  private bool select_node( Node? n ) {
    if( n != null ) {
      if( n != _current_node ) {
        if( _current_node != null ) {
          _current_node.mode = NodeMode.NONE;
        }
        _current_node = n;
        _current_new  = false;
        _current_node.mode = NodeMode.CURRENT;
        see();
        node_changed();
      }
      return( true );
    }
    return( false );
  }

  /* Returns true if there is a root that is available for selection */
  public bool root_selectable() {
    return( (_current_node == null) ? (_nodes.length > 0) : (_current_node.get_root() != _current_node) );
  }

  /*
   If there is no current node, selects the first root node; otherwise, selects
   the current node's root node.
  */
  public void select_root_node() {
    if( _current_node == null ) {
      if( _nodes.length > 0 ) {
        if( select_node( _nodes.index( 0 ) ) ) {
          queue_draw();
        }
      }
    } else {
      if( select_node( _current_node.get_root() ) ) {
        queue_draw();
      }
    }
  }

  /* Returns true if there is a next sibling available for selection */
  public bool sibling_selectable() {
    return( (_current_node != null) && (_current_node.is_root() ? (_nodes.length > 1) : (_current_node.parent.children().length > 1)) );
  }

  /* Selects the next (dir = 1) or previous (dir = -1) sibling */
  public void select_sibling_node( int dir ) {
    if( _current_node != null ) {
      Array<Node> nodes;
      int         index = 0;
      if( _current_node.is_root() ) {
        nodes = _nodes;
        for( int i=0; i<_nodes.length; i++ ) {
          if( _nodes.index( i ) == _current_node ) {
            index = i;
            break;
          }
        }
      } else {
        nodes = _current_node.parent.children();
        index = _current_node.index();
      }
      if( (index + dir) < 0 ) {
        if( select_node( nodes.index( nodes.length - 1 ) ) ) {
          queue_draw();
        }
      } else {
        if( select_node( nodes.index( (index + dir) % nodes.length ) ) ) {
          queue_draw();
        }
      }
    }
  }

  /* Returns true if there is a child node of the current node */
  public bool child_selectable() {
    return( (_current_node != null) && !_current_node.is_leaf() && !_current_node.folded );
  }

  /* Selects the first child node of the current node */
  public void select_first_child_node() {
    if( (_current_node != null) && !_current_node.is_leaf() && !_current_node.folded ) {
      if( select_node( _current_node.children().index( 0 ) ) ) {
        queue_draw();
      }
    }
  }

  /* Returns true if there is a parent node of the current node */
  public bool parent_selectable() {
    return( (_current_node != null) && !_current_node.is_root() );
  }

  /* Selects the parent node of the current node */
  public void select_parent_node() {
    if( (_current_node != null) && !_current_node.is_root() ) {
      if( select_node( _current_node.parent ) ) {
        queue_draw();
      }
    }
  }

  /* Returns true if we can perform a node deletion operation */
  public bool node_deleteable() {
    return( _current_node != null );
  }

  /* Deletes the given node */
  public void delete_node() {
    if( _current_node == null ) return;
    undo_buffer.add_item( new UndoNodeDelete( _current_node ) );
    if( _current_node.is_root() ) {
      for( int i=0; i<_nodes.length; i++ ) {
        if( _nodes.index( i ) == _current_node ) {
          _nodes.remove_index( i );
          break;
        }
      }
    } else {
      _current_node.delete( _layout );
    }
    _current_node.mode = NodeMode.NONE;
    _current_node = null;
    queue_draw();
    node_changed();
    changed();
  }

  /* Called whenever the backspace character is entered in the drawing area */
  private void handle_backspace() {
    if( is_mode_edit() ) {
      _current_node.edit_backspace( _layout );
      queue_draw();
      changed();
    } else if( is_mode_selected() ) {
      delete_node();
      _current_node = null;
    }
  }

  /* Called whenever the delete character is entered in the drawing area */
  private void handle_delete() {
    if( is_mode_edit() ) {
      _current_node.edit_delete( _layout );
      queue_draw();
      changed();
    } else if( is_mode_selected() ) {
      delete_node();
      _current_node = null;
    }
  }

  /* Called whenever the escape character is entered in the drawing area */
  private void handle_escape() {
    if( is_mode_edit() ) {
      _im_context.reset();
      _current_node.mode = NodeMode.CURRENT;
      _current_node.name = _orig_name;
      _layout.handle_update_by_edit( _current_node );
      queue_draw();
      changed();
    }
  }

  /* Adds a new root node to the canvas */
  public void add_root_node() {
    var node = new Node.with_name( this, _( "Another Idea" ), _layout );
    if (_nodes.length == 0) {
      node.posx = (get_allocated_width()  / 2) - 30;
      node.posy = (get_allocated_height() / 2) - 10;
    } else {
      _layout.position_root( _nodes.index( _nodes.length - 1 ), node );
    }
    _nodes.append_val( node );
    if( select_node( node ) ) {
      node.mode = NodeMode.EDITABLE;
      _current_new = true;
      queue_draw();
    }
    see();
    changed();
  }

  /* Adds a new sibling node to the current node */
  public void add_sibling_node() {
    var node = new Node( this, _layout );
    _orig_name = "";
    _current_node.mode = NodeMode.NONE;
    node.side          = _current_node.side;
    node.attach( _current_node.parent, (_current_node.index() + 1), _theme, _layout );
    undo_buffer.add_item( new UndoNodeInsert( node ) );
    if( select_node( node ) ) {
      node.mode = NodeMode.EDITABLE;
      _current_new = true;
      queue_draw();
    }
    see();
    changed();
  }

  /* Called whenever the return character is entered in the drawing area */
  private void handle_return() {
    if( is_mode_edit() ) {
      if( !_current_new ) {
        undo_buffer.add_item( new UndoNodeName( _current_node, _orig_name ) );
      }
      _current_node.mode = NodeMode.CURRENT;
      node_changed();
      queue_draw();
    } else if( !_current_node.is_root() ) {
      add_sibling_node();
    } else {
      add_root_node();
    }
  }

  /* Adds the given node to the list of root nodes */
  public void add_root( Node n, int index ) {
    if( index == -1 ) {
      _nodes.append_val( n );
    } else {
      _nodes.insert_val( index, n );
    }
  }

  /* Removes the node at the given root index from the list of root nodes */
  public void remove_root( int index ) {
    _nodes.remove_index( index );
  }

  /* Returns true if the drawing area has a node that is available for detaching */
  public bool detachable() {
    return( (_current_node != null) && (_current_node.parent != null) );
  }

  /* Detaches the current node from its parent and adds it as a root node */
  public void detach() {
    if( !detachable() ) return;
    Node     parent = _current_node.parent;
    int      index  = _current_node.index();
    NodeSide side   = _current_node.side;
    _current_node.detach( side, _layout );
    add_root( _current_node, -1 );
    undo_buffer.add_item( new UndoNodeDetach( _current_node, (int)_nodes.length, parent, side, index ) );
    queue_draw();
    changed();
  }

  /* Balances the existing nodes based on the current layout */
  public void balance_nodes( bool undoable = true ) {
    if( undoable ) {
      undo_buffer.add_item( new UndoNodeBalance( this ) );
    }
    if( (_current_node == null) || !undoable ) {
      animator.add_nodes( "balance nodes" );
      for( int i=0; i<_nodes.length; i++ ) {
        var partitioner = new Partitioner();
        partitioner.partition_node( _nodes.index( i ), _layout );
      }
    } else {
      Node current_root = _current_node.get_root();
      animator.add_node( current_root, "balance tree" );
      var partitioner = new Partitioner();
      partitioner.partition_node( current_root, _layout );
    }
    animator.animate();
    grab_focus();
  }

  /* Returns true if there is at least one node that can be folded due to completed tasks */
  public bool completed_tasks_foldable() {
    if( _current_node != null ) {
      return( _current_node.get_root().completed_tasks_foldable() );
    } else {
      for( int i=0; i<_nodes.length; i++ ) {
        if( _nodes.index( i ).completed_tasks_foldable() ) {
          return( true );
        }
      }
    }
    return( false );
  }

  /* Folds all completed tasks found in any tree */
  public void fold_completed_tasks() {
    var changes = new Array<Node>();
    if( _current_node == null ) {
      for( int i=0; i<_nodes.length; i++ ) {
        _nodes.index( i ).fold_completed_tasks( ref changes );
      }
    } else {
      _current_node.get_root().fold_completed_tasks( ref changes );
    }
    if( changes.length > 0 ) {
      for( int i=0; i<changes.length; i++ ) {
        _layout.handle_update_by_fold( changes.index( i ) );
      }
      undo_buffer.add_item( new UndoNodeFoldChanges( _( "fold completed tasks" ), changes, true ) );
      queue_draw();
      changed();
      node_changed();
    }
  }

  /* Returns true if there is at least one node that is unfoldable */
  public bool unfoldable() {
    if( _current_node != null ) {
      return( _current_node.get_root().unfoldable() );
    } else {
      for( int i=0; i<_nodes.length; i++ ) {
        if( _nodes.index( i ).unfoldable() ) {
          return( true );
        }
      }
    }
    return( false );
  }

  /* Unfolds all nodes in the document */
  public void unfold_all_nodes() {
    var changes = new Array<Node>();
    if( _current_node != null ) {
      _current_node.get_root().set_fold( false, ref changes );
    } else {
      for( int i=0; i<_nodes.length; i++ ) {
        _nodes.index( i ).set_fold( false, ref changes );
      }
    }
    if( changes.length > 0 ) {
      for( int i=0; i<changes.length; i++ ) {
        _layout.handle_update_by_fold( changes.index( i ) );
      }
      undo_buffer.add_item( new UndoNodeFoldChanges( _( "unfold all tasks" ), changes, false ) );
      queue_draw();
      changed();
      node_changed();
    }
  }

  /* Adds a child node to the current node */
  public void add_child_node() {
    var node = new Node( this, _layout );
    _orig_name = "";
    if( !_current_node.is_root() ) {
      node.side = _current_node.side;
    }
    _current_node.mode   = NodeMode.NONE;
    node.attach( _current_node, -1, _theme, _layout );
    undo_buffer.add_item( new UndoNodeInsert( node ) );
    _current_node.folded = false;
    _layout.handle_update_by_fold( _current_node );
    if( select_node( node ) ) {
      node.mode = NodeMode.EDITABLE;
      queue_draw();
    }
    see();
    changed();
  }

  /* Called whenever the tab character is entered in the drawing area */
  private void handle_tab() {
    if( is_mode_edit() ) {
      if( !_current_new ) {
        undo_buffer.add_item( new UndoNodeName( _current_node, _orig_name ) );
      }
      _current_node.mode = NodeMode.CURRENT;
      node_changed();
      queue_draw();
    } else if( is_mode_selected() ) {
      add_child_node();
    }
  }

  /* Called whenever the right key is entered in the drawing area */
  private void handle_right() {
    if( is_mode_edit() ) {
      _current_node.move_cursor( 1 );
      queue_draw();
    } else if( is_mode_selected() ) {
      Node? next;
      if( _current_node.is_root() ) {
        next = _current_node.first_child( NodeSide.RIGHT );
      } else {
        switch( _current_node.side ) {
          case NodeSide.TOP    :
          case NodeSide.BOTTOM :  next = _current_node.parent.next_child( _current_node );  break;
          case NodeSide.LEFT   :  next = _current_node.parent;  break;
          default              :  next = _current_node.first_child( NodeSide.RIGHT );  break;
        }
      }
      if( select_node( next ) ) {
        queue_draw();
      }
    }
  }

  /* Called whenever the left key is entered in the drawing area */
  private void handle_left() {
    if( is_mode_edit() ) {
      _current_node.move_cursor( -1 );
      queue_draw();
    } else if( is_mode_selected() ) {
      Node? next;
      if( _current_node.is_root() ) {
        next = _current_node.first_child( NodeSide.LEFT );
      } else {
        switch( _current_node.side ) {
          case NodeSide.TOP :
          case NodeSide.BOTTOM :  next = _current_node.parent.prev_child( _current_node );  break;
          case NodeSide.LEFT   :  next = _current_node.first_child( NodeSide.LEFT );  break;
          default              :  next = _current_node.parent;  break;
        }
      }
      if( select_node( next ) ) {
        queue_draw();
      }
    }
  }

  /* Called whenever the home key is entered in the drawing area */
  private void handle_home() {
    if( is_mode_edit() ) {
      _current_node.move_cursor_to_start();
      queue_draw();
    }
  }

  /* Called whenever the end key is entered in the drawing area */
  private void handle_end() {
    if( is_mode_edit() ) {
      _current_node.move_cursor_to_end();
      queue_draw();
    }
  }

  /* Called whenever the up key is entered in the drawing area */
  private void handle_up() {
    if( is_mode_edit() ) {
      _current_node.move_cursor_vertically( -1 );
      queue_draw();
    } else if( is_mode_selected() ) {
      if( _current_node.is_root() ) {
        for( int i=0; i<_nodes.length; i++ ) {
          if( _nodes.index( i ) == _current_node ) {
            if( i > 0 ) {
              if( select_node( _nodes.index( i - 1 ) ) ) {
                queue_draw();
              }
              return;
            }
          }
        }
      } else {
        Node? next;
        switch( _current_node.side ) {
          case NodeSide.TOP    :  next = _current_node.first_child( NodeSide.TOP );  break;
          case NodeSide.BOTTOM :  next = _current_node.parent;  break;
          default              :  next = _current_node.parent.prev_child( _current_node );  break;
        }
        if( select_node( next ) ) {
          queue_draw();
        }
      }
    }
  }

  /* Called whenever the down key is entered in the drawing area */
  private void handle_down() {
    if( is_mode_edit() ) {
      _current_node.move_cursor_vertically( 1 );
      queue_draw();
    } else if( is_mode_selected() ) {
      if( _current_node.is_root() ) {
        for( int i=0; i<_nodes.length; i++ ) {
          if( _nodes.index( i ) == _current_node ) {
            if( (i + 1) < _nodes.length ) {
              if( select_node( _nodes.index( i + 1 ) ) ) {
                queue_draw();
              }
              return;
            }
          }
        }
      } else {
        Node? next;
        switch( _current_node.side ) {
          case NodeSide.TOP    :  next = _current_node.parent;  break;
          case NodeSide.BOTTOM :  next = _current_node.first_child( NodeSide.BOTTOM );  break;
          default              :  next = _current_node.parent.next_child( _current_node );  break;
        }
        if( select_node( next ) ) {
          queue_draw();
        }
      }
    }
  }

  /* Called whenever the page up key is entered in the drawing area */
  private void handle_pageup() {
    if( is_mode_selected() ) {
      if( _current_node.is_root() ) {
        if( _nodes.length > 0 ) {
          if( select_node( _nodes.index( 0 ) ) ) {
            queue_draw();
          }
        }
      } else {
        if( select_node( _current_node.parent.first_child() ) ) {
          queue_draw();
        }
      }
    }
  }

  /* Called whenever the page down key is entered in the drawing area */
  private void handle_pagedn() {
    if( is_mode_selected() ) {
      if( _current_node.is_root() ) {
        if( _nodes.length > 0 ) {
          if( select_node( _nodes.index( _nodes.length - 1 ) ) ) {
            queue_draw();
          }
        }
      } else {
        if( select_node( _current_node.parent.last_child() ) ) {
          queue_draw();
        }
      }
    }
  }

  /* Called whenever a printable character is entered in the drawing area */
  private void handle_printable( string str ) {
    if( str.get_char( 0 ).isprint() ) {
      if( is_mode_edit() ) {
        _current_node.edit_insert( str, _layout );
        see();
        queue_draw();
        changed();
      } else if( is_mode_selected() ) {
        switch( str ) {
          case "e" :
            _current_node.mode = NodeMode.EDITABLE;
            queue_draw();
            break;
          case "n" :  select_sibling_node( 1 );  break;
          case "p" :  select_sibling_node( -1 );  break;
          case "a" :  select_parent_node();  break;
          case "f" :  toggle_fold( _current_node );  break;
          case "t" :  // Toggle the task done indicator
            if( _current_node.is_task() ) {
              toggle_task( _current_node );
            }
            break;
          case "m" :  select_root_node();  break;
          case "c" :  select_first_child_node();  break;
          case "C" :  center_current_node();  break;
          case "i" :  show_properties( "node", false );  break;
          case "u" :  // Perform undo
            if( undo_buffer.undoable() ) {
              undo_buffer.undo();
            }
            break;
          case "r" :  // Perform redo
            if( undo_buffer.redoable() ) {
              undo_buffer.redo();
            }
            break;
          case "s" :  see();  break;
          case "z" :  zoom_out();  break;
          case "Z" :  zoom_in();  break;
          default :
            // This is a key that doesn't have any associated functionality
            // so just return immediately so that we don't force a redraw
            return;
        }
      }
    }
  }

  /* Handle a key event */
  private bool on_keypress( EventKey e ) {

    /* Figure out which modifiers were used */
    var control = (bool) e.state & ModifierType.CONTROL_MASK;
    var shift   = (bool) e.state & ModifierType.SHIFT_MASK;
    var nomod   = !(control || shift);

    /* If there is a current node selected, operate on it */
    if( _current_node != null ) {
      if( control ) {
        switch( e.keyval ) {
          case 99  :  do_copy();   break;
          case 120 :  do_cut();    break;
          case 118 :  do_paste();  break;
        }
      } else if( nomod || shift ) {
        if( _im_context.filter_keypress( e ) ) {
          return( true );
        }
        switch( e.keyval ) {
          case 65288 :  handle_backspace();  break;
          case 65535 :  handle_delete();     break;
          case 65307 :  handle_escape();     break;
          case 65293 :  handle_return();     break;
          case 65289 :  handle_tab();        break;
          case 65363 :  handle_right();      break;
          case 65361 :  handle_left();       break;
          case 65360 :  handle_home();       break;
          case 65367 :  handle_end();        break;
          case 65362 :  handle_up();         break;
          case 65364 :  handle_down();       break;
          case 65365 :  handle_pageup();     break;
          case 65366 :  handle_pagedn();     break;
          default :
            //if( !e.str.get_char( 0 ).isprint() ) {
            //  stdout.printf( "In on_keypress, keyval: %s\n", e.keyval.to_string() );
            //}
            handle_printable( e.str );
            break;
        }
      }

    /* If there is no current node, allow some of the keyboard shortcuts */
    } else if( nomod || shift ) {
      switch( e.str ) {
        case "m" :  select_root_node();  break;
        case "u" :  if( undo_buffer.undoable() ) undo_buffer.undo();  break;
        case "r" :  if( undo_buffer.redoable() ) undo_buffer.redo();  break;
        case "z" :  zoom_out();  break;
        case "Z" :  zoom_in();   break;
      }
    }
    return( true );
  }

  /* Returns true if we can perform a node copy operation */
  public bool node_copyable() {
    return( _current_node != null );
  }

  /* Returns true if we can perform a node cut operation */
  public bool node_cuttable() {
    return( _current_node != null );
  }

  /* Returns true if we can perform a node paste operation */
  public bool node_pasteable() {
    return( node_clipboard != null );
  }

  /* Copies the current node to the node clipboard */
  public void copy_node_to_clipboard() {
    if( _current_node == null ) return;
    node_clipboard = new Node.copy_tree( _current_node, image_manager );
  }

  /* Copies the currently selected text to the clipboard */
  private void copy_selected_text() {
    if( _current_node == null ) return;
    string? value = _current_node.get_selected_text();
    if( value != null ) {
      var clipboard = Clipboard.get_default( get_display() );
      clipboard.set_text( value, -1 );
    }
  }

  /* Copies either the current node or the currently selected text to the clipboard */
  public void do_copy() {
    if( _current_node == null ) return;
    switch( _current_node.mode ) {
      case NodeMode.CURRENT  :  copy_node_to_clipboard();  break;
      case NodeMode.EDITABLE :  copy_selected_text();      break;
    }
  }

  /* Cuts the current node from the tree and stores it in the clipboard */
  public void cut_node_to_clipboard() {
    if( _current_node == null ) return;
    undo_buffer.add_item( new UndoNodeCut( this, _current_node ) );
    copy_node_to_clipboard();
    if( _current_node.is_root() ) {
      for( int i=0; i<_nodes.length; i++ ) {
        if( _nodes.index( i ) == _current_node ) {
          _nodes.remove_index( i );
          break;
        }
      }
    } else {
      _current_node.delete( _layout );
    }
    _current_node.mode = NodeMode.NONE;
    _current_node      = null;
    queue_draw();
    node_changed();
    changed();
  }

  /* Cuts the current selected text to the clipboard */
  private void cut_selected_text() {
    copy_selected_text();
    _current_node.edit_insert( "", _layout );
    queue_draw();
    changed();
  }

  /* Either cuts the current node or cuts the currently selected text */
  public void do_cut() {
    if( _current_node == null ) return;
    switch( _current_node.mode ) {
      case NodeMode.CURRENT  :  cut_node_to_clipboard();  break;
      case NodeMode.EDITABLE :  cut_selected_text();      break;
    }
  }

  /*
   Pastes the clipboard content as either a root node or to the currently
   selected node.
  */
  public void paste_node_from_clipboard() {
    if( node_clipboard == null ) return;
    Node node = new Node.copy_tree( node_clipboard, image_manager );
    if( _current_node == null ) {
      _layout.position_root( _nodes.index( _nodes.length - 1 ), node );
      add_root( node, -1 );
    } else {
      if( _current_node.is_root() ) {
        uint num_children = _current_node.children().length;
        if( num_children > 0 ) {
          node.side = _current_node.children().index( num_children - 1 ).side;
          _layout.propagate_side( node, node.side );
        }
      } else {
        node.side = _current_node.side;
        _layout.propagate_side( node, node.side );
      }
      node.attach( _current_node, -1, _theme, _layout );
    }
    undo_buffer.add_item( new UndoNodePaste( node ) );
    queue_draw();
    node_changed();
    changed();
  }

  /* Pastes the text that is in the clipboard to the node text */
  private void paste_text() {
    var clipboard = Clipboard.get_default( get_display() );
    string? value = clipboard.wait_for_text();
    if( value != null ) {
      _current_node.edit_insert( value, _layout );
      queue_draw();
      changed();
    }
  }

  /* Pastes the contents of the clipboard into the current node */
  public void do_paste() {
    if( _current_node == null ) return;
    switch( _current_node.mode ) {
      case NodeMode.CURRENT  :  paste_node_from_clipboard();  break;
      case NodeMode.EDITABLE :  paste_text();                 break;
    }
  }

  /* Clears the node clipboard */
  public void clear_node_clipboard() {
    node_clipboard = null;
  }

  /*
   Called whenever the user scrolls on the canvas.  We will adjust the
   origin to give the canvas the appearance of scrolling.
  */
  private bool on_scroll( EventScroll e ) {

    double delta_x, delta_y;
    e.get_scroll_deltas( out delta_x, out delta_y );

    bool shift   = (bool) e.state & ModifierType.SHIFT_MASK;
    bool control = (bool) e.state & ModifierType.CONTROL_MASK;

    /* Swap the deltas if the SHIFT key is held down */
    if( shift && !control ) {
      double tmp = delta_x;
      delta_x = delta_y;
      delta_y = tmp;
    } else if( control ) {
      if( e.delta_y < 0 ) {
        zoom_in();
      } else if( e.delta_y > 0 ) {
        zoom_out();
      }
      return( false );
    }

    /* Adjust the origin and redraw */
    move_origin( (delta_x * 120), (delta_y * 120) );
    queue_draw();

    /* When the end of the scroll occurs, save the scroll position to the file */
    auto_save();

    return( false );

  }

  /* Perform an automatic save for times when changes may be happening rapidly */
  private void auto_save() {
    if( _auto_save_id != null ) {
      Source.remove( _auto_save_id );
    }
    _auto_save_id = Timeout.add( 200, do_auto_save );
  }

  /* Allows the document to be auto-saved after a scroll event */
  private bool do_auto_save() {
    _auto_save_id = null;
    changed();
    return( false );
  }

  /* Called whenever we drag something over the canvas */
  private bool handle_drag_motion( Gdk.DragContext ctx, int x, int y, uint t ) {

    Node attach_node = droppable_node( scale_value( x ), scale_value( y ) );
    if( _attach_node != null ) {
      _attach_node.mode = NodeMode.NONE;
    }
    if( attach_node != null ) {
      attach_node.mode = NodeMode.DROPPABLE;
      _attach_node = attach_node;
      queue_draw();
    } else if( _attach_node != null ) {
      _attach_node = null;
      queue_draw();
    }

    return( true );

  }

  /* Called when something is dropped on the DrawArea */
  private void handle_drag_data_received( Gdk.DragContext ctx, int x, int y, Gtk.SelectionData data, uint info, uint t ) {

    if( (_attach_node == null) || (_attach_node.mode != NodeMode.DROPPABLE) ) {

      foreach (var uri in data.get_uris()) {
        var image = new NodeImage.from_uri( image_manager, uri, 200 );
        if( image.valid ) {
          var node = new Node.with_name( this, _( "Another Idea" ), _layout );
          node.set_image( image_manager, image );
          _layout.position_root( _nodes.index( _nodes.length - 1 ), node );
          _nodes.append_val( node );
          if( select_node( node ) ) {
            node.mode = NodeMode.EDITABLE;
            _current_new = true;
            queue_draw();
          }
        }
      }

      Gtk.drag_finish( ctx, true, false, t );

      see();
      queue_draw();
      node_changed();
      auto_save();

    } else if( (_attach_node.mode == NodeMode.DROPPABLE) && (data.get_uris().length == 1) ) {

      var image = new NodeImage.from_uri( image_manager, data.get_uris()[0], _attach_node.max_width() );
      if( image.valid ) {
        var orig_image = _attach_node.get_image();
        _attach_node.set_image( image_manager, image );
        undo_buffer.add_item( new UndoNodeImage( _attach_node, orig_image ) );
        _layout.handle_update_by_edit( _attach_node );
        _attach_node.mode = NodeMode.NONE;
        _attach_node      = null;
        Gtk.drag_finish( ctx, true, false, t );
        queue_draw();
        node_changed();
        auto_save();
      }

    }

  }

  /* Sets the image of the current node to the given filename */
  public bool update_current_image( string uri ) {
    var image = new NodeImage.from_uri( image_manager, uri, _current_node.max_width() );
    if( image.valid ) {
      var orig_image = _current_node.get_image();
      _current_node.set_image( image_manager, image );
      undo_buffer.add_item( new UndoNodeImage( _current_node, orig_image ) );
      _layout.handle_update_by_edit( _current_node );
      queue_draw();
      node_changed();
      auto_save();
      return( true );
    }
    return( false );
  }

}
