(define-module (battery info))

(use-modules
  (ice-9 atomic) (ice-9 exceptions) (ice-9 match)
  (ice-9 textual-ports) (ice-9 threads)
  (sxml simple) (sxml xpath))

(use-modules (g-golf))

(use-modules (gtk))

(g-irepository-require "Gtk" #:version "4.0")

(gi-import-by-name "Gdk" "Clipboard")
(gi-import-by-name "Gdk" "Display")
(gi-import-by-name "Gio" "Application")
(gi-import-by-name "Gio" "DBusProxy")
(gi-import-by-name "Gtk" "Box")
(gi-import-by-name "Gtk" "Button")
(gi-import-by-name "Gtk" "Label")
(gi-import-by-name "Gtk" "ScrolledWindow")
(gi-import-by-name "Gtk" "Spinner")
(gi-import-by-name "Adw" "HeaderBar")
(gi-import-by-name "Adw" "Application")
(gi-import-by-name "Adw" "ApplicationWindow")
(gi-import-by-name "Adw" "StatusPage")
(gi-import-by-name "Adw" "ToastOverlay")

(bindtextdomain "battery-info" "locale")
(textdomain "battery-info")

(define (vertical-box . children)
  (define box (make <gtk-box> #:orientation 'vertical))
  (for-each (lambda (child) (append box child)) children)
  box)

(define* (h1 title #:key selectable)
  (make <gtk-label> #:css-classes (list "title-1") #:margin-bottom 5
    #:label title #:selectable selectable))

(define (loading)
  (define spinner (make <gtk-spinner> #:margin-top 40 #:margin-bottom 40
    #:width-request 40 #:height-request 40))
  (start spinner)
  (vertical-box spinner (h1 (gettext "Loading"))))

(define (no-battery)
  (make <adw-status-page>
    #:icon-name "system-search-symbolic"
    #:title (gettext "No battery detected.")))

(define (info-error exception)
  (make <adw-status-page>
    #:icon-name "dialog-error-symbolic"
    #:title (gettext "Error reading battery info.")
    #:description (exception-message exception)))

(define (info-line description value)
  (define label (make <gtk-label> #:selectable #t))
  (set-markup label (format #f "~a <b>~a</b>" description value))
  label)

(define (vertical-glue) (make <gtk-label> #:valign 'fill #:vexpand #t))

(define (meta-line text)
  (define label (make <gtk-label>))
  (set-markup label (format #f "<i>~a</i>" text))
  label)

(define (join null a b)
  (define s
    (filter (lambda (value) (and value (not (equal? "" value)))) (list a b)))
  (if (null? s) null (string-join s)))

(define (capacity->string value)
  (match value
    ((and (? real?) (not 0.0))
     (format #f "~a Wh" (/ (round (* value 100)) 100)))
    (else (gettext "Unknown"))))

(define (layout info)
  (vertical-box
    (h1
      (join (gettext "Unknown Battery") (assoc-ref info 'vendor) (assoc-ref info 'model))
      #:selectable #t)
    (info-line (gettext "System")
      (join (gettext "Unknown") (assoc-ref info 'sys-vendor) (assoc-ref info 'sys-model)))
    (info-line (gettext "Technology")
      (match (assoc-ref info 'technology)
        (1 (gettext "Lithium ion"))
        (2 (gettext "Lithium polymer"))
        (3 (gettext "Lithium iron phosphate"))
        (4 (gettext "Lead acid"))
        (5 (gettext "Nickel cadmium"))
        (6 (gettext "Nickel metal hydride"))
        (else (gettext "Unknown"))))
    (info-line (gettext "Nominal capacity")
      (capacity->string (assoc-ref info 'energy-full-design)))
    (info-line (gettext "Actual capacity")
      (capacity->string (assoc-ref info 'energy-full)))
    (info-line (gettext "Capacity percentage")
      (match (assoc-ref info 'capacity)
        ((and (? real?) (not 0.0) capacity) (format #f "~a%" (round capacity)))
        (else (gettext "Unknown"))))))

(define (copy-to-clipboard text)
  (define clipboard (get-clipboard (gdk-display-get-default)))
  (set clipboard text))

(define-syntax define-traced
  (syntax-rules ()
    ((define-traced (name ...) exp ...)
     (define (name ...)
       (format #t "trace ~a\n" (list name ...))
       ((lambda () exp ...))))))

(define (battery-info info)
  (define view (layout info))
  (define scrolled
    (make <gtk-scrolled-window> #:propagate-natural-height #t #:width-request 120 #:height-request 100
       #:child view))
  (define copy-button
    (make <gtk-button> #:label (gettext "Copy") #:margin-top 15 #:halign 'center))
  (define toast-overlay (make <adw-toast-overlay> #:child scrolled))
  (define previous-toast #f)
  (connect copy-button 'clicked
    (lambda (b)
      (copy-to-clipboard (text view))
      (if previous-toast (dismiss previous-toast))
      (let ((toast (make <adw-toast> #:title (gettext "Info copied to clipboard."))))
        (add-toast toast-overlay toast)
        (if previous-toast (unref previous-toast))
        (set! previous-toast (ref toast)))))
  (vertical-box toast-overlay copy-button))

(define (window-content state)
  (define content
    (match (atomic-box-ref state)
      ('loading (loading))
      ('no-battery (no-battery))
      ((? exception? exception) (info-error exception))
      (info (battery-info info))))
  (define bordered
    (make <gtk-box> #:orientation 'vertical #:margin-top 10 #:margin-bottom 10
      #:margin-left 10 #:margin-right 10))
  (append bordered content)
  (append bordered (vertical-glue))
  (append bordered (meta-line (gettext "Made by Michal Herko")))
  (vertical-box (make <adw-header-bar>) bordered))

(define-public battery-info-app
  (make <adw-application> #:application-id "com.her01n.BatteryInfo"))

(register battery-info-app #f)

(define (present-window)
  (define window
    (make <adw-application-window> #:application battery-info-app
      #:title (gettext "Battery Info")))
  (set-default-size window 480 480)
  (present window)
  window)

(define (update window state)
  (define content (window-content state))
  ; workaround to avoid selecting the battery name
  (set-content window #f)
  (g-idle-add (lambda () (set-content window content) #f)))

(define (load window state get-info)
  (define get-info-proc
    (if (procedure? get-info) get-info (lambda () get-info)))
  (with-exception-handler
    (lambda (exception) (atomic-box-set! state exception))
    (lambda () (atomic-box-set! state (or (get-info-proc) 'no-battery)))
    #:unwind? #t)
  (g-idle-add (lambda () (update window state) #f)))

(define-public (show-battery-info get-info)
  (define state (make-atomic-box 'loading))
  (define window (present-window))
  ; delay displaying the spinner a little,
  ; so it does not blink if the loading is fast
  (g-timeout-add 200 (lambda () (update window state) #f))
  (begin-thread (load window state get-info))
  window)

(define (g-variant->scm variant)
  (define (g-variant->list)
    (map
      (lambda (i) (g-variant->scm (g-variant-get-child-value variant i)))
      (iota (g-variant-n-children variant))))  
  (match (g-variant-classify variant)
    ('boolean (g-variant-get-boolean variant))
    ('uint32 (g-variant-get-uint32 variant))
    ('double (g-variant-get-double variant))
    ('string (g-variant-get-string variant))
    ('object-path (g-variant-get-string variant))
    ('signature (g-variant-get-string variant))
    ('variant (g-variant->scm (g-variant-get-child-value variant 0)))
    ('array (list->vector (g-variant->list)))
    ('tuple (g-variant->list))))

(define timeout 1000)

(define (get-property proxy name)
  (car
    (g-variant->scm
      (call-sync
        proxy "Get"
        (g-variant-parse #f (format #f "(\"~a\", \"~a\")" "org.freedesktop.UPower.Device" name) #f #f)
        '() timeout #f))))

(define-public (get-upower-info)
  ; list objects of system org.freedesktop.UPower service
  (define upower-proxy
    (gd-bus-proxy-new-for-bus-sync
      'system '() #f "org.freedesktop.UPower" "/org/freedesktop/UPower" "org.freedesktop.UPower" #f))
  (define devices-names
    (vector->list
      (car (g-variant->scm (call-sync upower-proxy "EnumerateDevices" #f '() timeout #f)))))
  ; find a battery and query the information
  (find identity
    (map
      (lambda (device)
        (define proxy
          (gd-bus-proxy-new-for-bus-sync
            'system '() #f "org.freedesktop.UPower" device "org.freedesktop.DBus.Properties" #f))
        (and
          (equal? (get-property proxy "Type") 2)
          (get-property proxy "PowerSupply")
          `((vendor . ,(get-property proxy "Vendor"))
            (model . ,(get-property proxy "Model"))
            (energy-full-design . ,(get-property proxy "EnergyFullDesign"))
            (technology . ,(get-property proxy "Technology"))
            (energy-full . ,(get-property proxy "EnergyFull"))
            (capacity . ,(get-property proxy "Capacity")))))
      devices-names)))

(define (read-dmi key)
  (define string
    (call-with-input-file
      (string-append "/sys/devices/virtual/dmi/id/" key)
      (@ (ice-9 textual-ports) get-line)))
  (match string
    ("" #f)
    ("Default String" #f)
    ("To Be Filled By O.E.M." #f)
    (value value)))

(define (get-dmi-info)
  (with-exception-handler
    (lambda (exception)
      (format #t "Failed to get dmi info: ~a\n" (exception-message exception))
      '())
    (lambda ()
      `((sys-vendor . ,(read-dmi "sys_vendor"))
        (sys-model . ,(read-dmi "product_name"))))
    #:unwind? #t))

(define (get-battery-info)
  (define upower (get-upower-info))
  (and (list? upower) (append upower (get-dmi-info))))

(define-public (main args)
  (connect battery-info-app 'activate
    (lambda (app)
      (show-battery-info get-info)))
  (run battery-info-app args))

