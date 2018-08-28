;;; imdb-mode.el --- querying the imdb movie database -*- lexical-binding: t -*-
;; Copyright (C) 2018 Lars Magne Ingebrigtsen

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: movies

;; This file is not part of GNU Emacs.

;; imdb.el is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; imdb.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; To work, this needs the sqlite3 module
;; https://github.com/syohex/emacs-sqlite3
;; which needs:

;; sudo apt install sqlite3-pcre libsqlite3-dev

;; The Emacs has to be pretty new -- anything older than Emacs 26
;; probably won't work.  And it has to be built with module support.

;; After getting all that set up, you need to download the IMDB
;; dataset and create the sqlite3 database, which can be done with
;; this:

;; (imdb-download-and-create)

;; This will take several hours and use 10GB of disk space.  Emacs
;; will not be usable while this is going on.

;; Usage: `M-x imdb-person' or `M-x imdb-film'

;;; Code:

(eval-when-compile
  (setq byte-compile-warnings '(not cl-functions)))

(require 'imdb)
(require 'sqlite3)
(require 'cl)
(require 'browse-url)

(defvar imdb-mode-regexp-p nil)

(defvar imdb-db nil)

(defvar imdb-mode-extra-data nil)
(defvar imdb-mode-filter-insignificant nil)
(defvar imdb-mode-filter-job nil)
(defvar imdb-mode-mode nil)
(defvar imdb-mode-search nil)

(defvar imdb-tables
  '((movie
     (mid text :primary)
     (type text)
     (primary-title text)
     (original-title text)
     (adultp bool)
     (start-year integer)
     (end-year integer)
     (length integer))
    (movie-genre
     (mid text :references movie)
     (genre text))
    
    (person
     (pid text :primary)
     (primary-name text)
     (birth-year integer)
     (death-year integer))
    (person-primary-profession
     (pid text :references person)
     (profession text))
    (person-known-for
     (pid text :references person)
     (mid text :references movie))

    (title
     (mid text :references movie)
     (rank integer)
     (title text)
     (region text)
     (language text)
     (types text)
     (attributes text)
     (originalp bool))

    (crew
     (mid text :references movie)
     (pid text :references person)
     (category text))
     
    (episode
     (mid text :primary :references movie)
     (movie text :references movie)
     (season integer)
     (episode integer))

    (rating
     (mid text :primary :references movie)
     (rating real)
     (votes integer))

    (principal
     (mid text :references movie)
     (rank integer)
     (pid text :references person)
     (category text)
     (job text))

    (principal-character
     (mid text :references movie)
     (pid text :references person)
     (character text))))

(defun imdb-dehyphenate (elem)
  (replace-regexp-in-string "-" "_" (symbol-name elem)))

(defun imdb-hyphenate (elem)
  (replace-regexp-in-string "_" "-" elem))

(defun imdb-download-and-create ()
  "Download the IMDB data files and create the sqlite3 database.
This will take some hours and use 10GB of disk space."
  (imdb-download-data)
  (imdb-create-tables)
  (imdb-read-data)
  (imdb-create-indices))

(defun imdb-download-data ()
  (let ((dom
	 (with-current-buffer (url-retrieve-synchronously
			       "https://datasets.imdbws.com/")
	   (goto-char (point-min))
	   (search-forward "\n\n")
	   (prog1
	       (libxml-parse-html-region (point) (point-max))
	     (kill-buffer (current-buffer))))))
    (loop for elem in (dom-by-tag dom 'a)
	  for url = (dom-attr elem 'href)
	  when (string-match "[.]gz\\'" url)
	  do (imdb-download-data-1 url))))

(defun imdb-download-data-1 (url)
  (with-current-buffer (url-retrieve-synchronously url)
    (goto-char (point-min))
    (search-forward "\n\n")
    (zlib-decompress-region (point) (point-max))
    (let ((file (expand-file-name (replace-regexp-in-string
				   "[.]gz\\'" ""
				   (file-name-nondirectory
				    (url-filename
				     (url-generic-parse-url url))))
				  "~/.emacs.d/imdb")))
      (unless (file-exists-p (file-name-directory file))
	(make-directory (file-name-directory file) t))
      (write-region (point) (point-max) file))
    (kill-buffer (current-buffer))))

(defun imdb-initialize ()
  (unless imdb-db
    (setq imdb-db (sqlite3-new
		   (file-truename "~/.emacs.d/imdb/imdb.sqlite3")))
    (when (sqlite3-load-extension imdb-db "/usr/lib/sqlite3/pcre.so")
      (setq imdb-mode-regexp-p t))))

(defun imdb-create-tables ()
  (imdb-initialize)
  (loop for (table . columns) in imdb-tables
	do (sqlite3-execute-batch
	    imdb-db (format
		     "create table if not exists %s (%s)"
		     (imdb-dehyphenate table)
		     (mapconcat
		      #'identity
		      (loop for elem in columns
			    collect (format
				     "%s %s%s%s"
				     (imdb-dehyphenate (car elem))
				     (if (equal (cadr elem) 'bool)
					 "text"
				       (cadr elem))
				     (if (memq :primary elem)
					 " primary key"
				       "")
				     (let ((references
					    (cadr (memq :references elem))))
				       (if references
					   (format " references %s"
						   references)
					 ""))))
		      ", ")))))

(defun imdb-create-indices ()
  (imdb-create-index
   "pcidx on principal_character(mid, pid)"
   "mgidx on movie_genre(mid)"
   "pppidx on person_primary_profession(pid)"
   "pkfidx on person_known_for(pid)"
   "tidx on title(mid)"
   "cidx on crew(mid, pid)"
   "eidx on episode(movie)"
   "pidx on principal(mid, pid)"
   "ppidx on principal(pid)"))

(defun imdb-create-index (&rest statements)
  (dolist (statement statements)
    (sqlite3-execute-batch
     imdb-db (concat "create index if not exists " statement))))

(defun imdb-read-line ()
  (loop for elem in (split-string
		     (buffer-substring (point) (line-end-position))
		     "\t")
	collect (if (equal elem "\\N")
		    nil
		  elem)))

(defun imdb-read-tsv (tables file function)
  (with-temp-buffer
    (dolist (table tables)
      (sqlite3-execute-batch imdb-db (format "delete from %s"
					     (imdb-dehyphenate table))))
    (sqlite3-transaction imdb-db)
    (insert-file-contents (format "~/.emacs.d/imdb/%s.tsv" file))
    (forward-line 1)
    (let ((lines 1)
	  (total (count-lines (point-min) (point-max))))
      (while (not (eobp))
	(when (zerop (% (incf lines) 1000))
	  (message "%s: Read %d lines (%.1f%%)" file lines
		   (* (/ (* lines 1.0) total) 100)))
	(funcall function (imdb-read-line))
	(forward-line 1)))
    (sqlite3-commit imdb-db)))

(defun imdb-read-simple (table file)
  (imdb-read-tsv
   (list table) file
   (lambda (elem)
     (imdb-insert (imdb-make table elem)))))

(defun imdb-read-data ()
  (imdb-read-tsv
   '(movie movie-genre) "title.basics"
   (lambda (elem)
     (imdb-insert (imdb-make 'movie elem))
     (when (car (last elem))
       (loop for genre in (split-string (car (last elem)) ",")
	     do (imdb-insert (imdb-make 'movie-genre
					(list (car elem) genre)))))))

  (imdb-read-tsv
   '(person person-primary-profession person-known-for)
   "name.basics"
   (lambda (elem)
     (imdb-insert (imdb-make 'person elem))
     (let ((professions (car (last elem 2)))
	   (known (car (last elem))))
       (when professions
	 (loop for profession in (split-string professions ",")
	       do (imdb-insert (imdb-make 'person-primary-profession
					  (list (car elem) profession)))))
       (when known
	 (loop for k in (split-string known ",")
	       do (imdb-insert (imdb-make 'person-known-for
					  (list (car elem) k))))))))

  (imdb-read-simple 'title "title.akas")

  (imdb-read-tsv
   '(crew) "title.crew"
   (lambda (elem)
     (let ((directors (cadr elem))
	   (writers (caddr elem)))
       (when directors
	 (dolist (mid (split-string directors ","))
	   (imdb-insert (imdb-make 'crew (list (car elem) mid "director")))))
       (when writers
	 (dolist (mid (split-string writers ","))
	   (imdb-insert (imdb-make 'crew (list (car elem) mid "writer"))))))))

  (imdb-read-simple 'episode "title.episode")
  (imdb-read-simple 'rating "title.ratings")

  (imdb-read-tsv
   '(principal principal-character) "title.principals"
   (lambda (elem)
     (let* ((object (imdb-make 'principal elem)))
       (imdb-insert object)
       (when (car (last elem))
	 (with-temp-buffer
	   (insert (car (last elem)))
	   (goto-char (point-min))
	   (loop for character across (json-read)
		 do (imdb-insert (imdb-make 'principal-character
					    (list (getf object :mid)
						  (getf object :pid)
						  character))))))))))

(defun imdb-make (table values)
  (nconc (list :_type table)
	 (loop for column in (cdr (assq table imdb-tables))
	       for value in values
	       for type = (cadr column)
	       append (list (intern (format ":%s" (car column)) obarray)
			    (cond
			     ((and value
				   (or (eq type 'integer)
				       (eq type 'number)
				       (eq type 'float)))
			      (string-to-number value))
			     ((eq type 'bool)
			      (if (equal value "0")
				  "N"
				"Y"))
			     (t
			      value))))))

(defun imdb-exec (statement values)
  (sqlite3-execute-batch imdb-db statement values))

(defun imdb-column-name (column)
  (replace-regexp-in-string ":" "" (imdb-dehyphenate column)))

(defvar imdb-db-test nil)

(defun imdb-insert (object)
  (unless imdb-db-test
    (imdb-exec
     (format "insert into %s(%s) values(%s)"
	     (imdb-dehyphenate (getf object :_type))
	     (mapconcat
	      #'identity
	      (loop for (column nil) on (cddr object) by #'cddr
		    collect (imdb-column-name column))
	      ",")
	     (mapconcat
	      #'identity
	      (loop repeat (/ (length (cddr object)) 2)
		    collect "?")
	      ","))
     (coerce
      (loop for (nil value) on (cddr object) by #'cddr
	    collect value)
      'vector))))

(defun imdb-select (table &rest values)
  (apply 'imdb-find table (loop for (key val) on values by #'cddr
				append (list key '= val))))


(defun imdb-select-where (statement &rest values)
  (imdb-initialize)
  (let ((result nil))
    (sqlite3-execute
     imdb-db
     statement
     (coerce values 'vector)
     (lambda (row names)
       (push
	(nconc (loop for value in row
		     for column in names
		     append (list
			     (intern (format ":%s"
					     (imdb-hyphenate
					      (replace-regexp-in-string
					       "[^_a-zA-Z0-9]" "" column)))
				     obarray)
			     value)))
	result)))
    (nreverse result)))

(defun imdb-find (table &rest values)
  (imdb-initialize)
  (let ((result nil))
    (sqlite3-execute
     imdb-db
     (format
      "select * from %s where %s"
      (imdb-dehyphenate table)
      (mapconcat
       #'identity
       (loop for (column predicate nil) on values by #'cdddr
	     collect (format "%s %s ?"
			     (imdb-column-name column)
			     predicate))
       " and "))
     (coerce
      (loop for (nil nil value) on values by #'cdddr
	    collect value)
      'vector)
     (lambda (row names)
       (push (nconc (list :_type table)
		    (loop for value in row
			  for column in names
			  append (list
				  (intern (format ":%s" (imdb-hyphenate column))
					  obarray)
				  value)))
	     result)))
    (nreverse result)))

(defvar imdb-mode-map
  (let ((map (make-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "f" 'imdb-film)
    (define-key map "p" 'imdb-person)
    (define-key map "x" 'imdb-mode-toggle-insignificant)
    (define-key map "l" 'imdb-mode-load-all-images)
    (define-key map "a" 'imdb-mode-show-acting)
    (define-key map "d" 'imdb-mode-show-directing)
    (define-key map "&" 'imdb-mode-open-imdb)
    (define-key map "w" 'imdb-mode-copy-url)
    (define-key map "q" 'kill-current-buffer)
    (define-key map " " 'imdb-mode-mark-line)
    (define-key map "\r" 'imdb-mode-select)
    (define-key map "m" 'imdb-mode-display-intersection)
    map))

(define-derived-mode imdb-mode special-mode "Imdb"
  "Major mode for examining the imdb database.

\\{imdb-mode-map}"
  (setq buffer-read-only t)
  (buffer-disable-undo)
  (setq-local imdb-mode-filter-insignificant t)
  (setq-local imdb-mode-filter-job nil)
  (setq-local imdb-mode-mode 'film-search)
  (setq-local imdb-mode-search nil)
  (setq-local imdb-mode-extra-data nil)
  (setq truncate-lines t))

(defun imdb-search (film)
  "Create a buffer to examine the imdb database."
  (interactive "sFilm: ")
  (switch-to-buffer "*imdb*")
  (imdb-initialize)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (imdb-mode)
    (imdb-film film)))

(defun imdb-mode-mark-line ()
  "Toggle marking of the current line."
  (interactive)
  (let ((id (get-text-property (point) 'id))
	(inhibit-read-only t))
    (unless id
      (error "Nothing on the current line"))
    (let ((marked (get-text-property (line-beginning-position) 'mark)))
      (add-face-text-property
       (line-beginning-position) (line-end-position)
       (list :weight (if marked 'normal 'bold)))
      (put-text-property (line-beginning-position)
			 (1+ (line-beginning-position))
			 'mark (not marked)))))

(defun imdb-mode-display-intersection ()
  "Show films that have all the people involved."
  (interactive)
  (let ((pids nil)
	match)
    (save-excursion
      (goto-char (point-min))
      (while (setq match (text-property-search-forward 'mark t t))
	(push (get-text-property (prop-match-beginning match) 'id) pids)))
    (unless pids
      (error "No marked people"))
    (switch-to-buffer (format "*imdb %s*"
			      (mapconcat
			       (lambda (pid)
				 (getf (car (imdb-select 'person :pid pid))
				       :primary-name))
			       pids
			       ",")))
    (let ((inhibit-read-only t))
      (imdb-mode)
      (imdb-mode-display-intersection-1
       pids
       (loop for pid in pids
	     collect (imdb-person-query-films pid))))))

(defun imdb-face (string &optional props)
  (setq string (if (stringp string)
		   string
		 (format "%s" string)))
  (propertize string
	      'face (cond
		     ((null props)
		      'variable-pitch)
		     ((stringp props)
		      `(variable-pitch (:foreground ,props)))
		     (t
		      `(variable-pitch ,props)))))		

(defun imdb-mode-display-intersection-1 (pids all)
  (let ((inhibit-read-only t)
	;; Find the intersection (i.e., films that all the people
	;; concerned have appeared in).
	(films
	 (loop for film in (car all)
	       when (every
		     #'identity
		     (loop for other in (cdr all)
			   collect
			   (cl-member
			    film other
			    :test (lambda (e1 e2)
				    (equal (getf e1 :mid)
					   (getf e2 :mid))))))
	       collect film)))
    ;; Remove duplicates.
    (setq films
	  (cl-remove-duplicates films
				:key (lambda (e) (getf e :mid))
				:test #'equal))
    (erase-buffer)
    (imdb-kill)
    (dolist (pid pids)
      (let ((start (point)))
	(imdb-insert-placeholder 300 400)
	(put-text-property start (point) 'id pid)
	(insert " ")))
    (imdb-load-people-images pids (current-buffer) 300 400 0)
    (insert "\n\n")
    (dolist (pid pids)
      (let ((person (car (imdb-select 'person :pid pid))))
	(insert
	 (imdb-face (getf person :primary-name) "#f0f0f0"))
	(when (getf person :birth-year)
	  (insert
	   (imdb-face (format " (%s)" (getf person :birth-year)) "#a0a0a0"))))
      (insert " "))
    (insert "\n\n")
    (setq imdb-mode-mode 'intersection
	  imdb-mode-search (list pids all))
    (setq films (cl-sort
		 (reverse films) '<
		 :key (lambda (e)
			(or (getf e :start-year) 1.0e+INF))))
    (setq films (imdb-mode-filter films))
    (dolist (film films)
      (imdb-mode-person-film film (car pids)))
    (goto-char (point-min))
    (forward-line 2)))

(defun imdb-mode-toggle-insignificant ()
  "Toggle whether to list proper films only."
  (interactive)
  (setq imdb-mode-filter-insignificant
	(not imdb-mode-filter-insignificant))
  (message "Unimportant items are now %s"
	   (if imdb-mode-filter-insignificant
	       "filtered"
	     "not filtered"))
  (imdb-mode-refresh-buffer))

(defun imdb-mode-show-acting ()
  "Show only acting."
  (interactive)
  (setq imdb-mode-filter-job
	(if (eq imdb-mode-filter-job 'acting)
	    nil
	  'acting))
  (message
   (if imdb-mode-filter-job
       "Only showing acting"
     "Showing all jobs"))
  (imdb-mode-refresh-buffer))

(defun imdb-mode-show-directing ()
  "Show only directing."
  (interactive)
  (setq imdb-mode-filter-job
	(if (eq imdb-mode-filter-job 'directing)
	    nil
	  'directing))
  (message
   (if imdb-mode-filter-job
       "Only showing directing"
     "Showing all jobs"))
  (imdb-mode-refresh-buffer))

(defun imdb-mode-refresh-buffer ()
  (let ((ids (save-excursion
	       (loop repeat 20
		     while (not (eobp))
		     collect (get-text-property (point) 'id)
		     do (forward-line 1)))))
  (cond
   ((eq imdb-mode-mode 'film-search)
    (imdb-mode-search-film-1 imdb-mode-search))
   ((eq imdb-mode-mode 'intersection)
    (imdb-mode-display-intersection-1 (car imdb-mode-search)
				      (cadr imdb-mode-search)))
   ((eq imdb-mode-mode 'person)
    (imdb-mode-display-person imdb-mode-search)))
  (if (not ids)
      (goto-char (point-max))
    (loop for id in ids
	  while (not (imdb-mode-goto-id id))))))

(defun imdb-mode-goto-id (id)
  (let ((start (point))
	match)
    (goto-char (point-min))
    (if (setq match (text-property-search-forward 'id id t))
	(progn
	  (goto-char (prop-match-beginning match))
	  (beginning-of-line)
	  t)
      (goto-char start)
      nil)))

(defun imdb-film (film)
  "List films matching FILM."
  (interactive (list (imdb-query-user "Film")))
  (switch-to-buffer (format "*imdb %s*" film))
  (let ((inhibit-read-only t))
    (imdb-mode)
    (setq imdb-mode-mode 'film-search
	  imdb-mode-search film)
    (erase-buffer)
    (imdb-mode-search-film-1 film)))

(defun imdb-mode-search-film-1 (film)
  (let ((films (if imdb-mode-regexp-p
		   (imdb-select-where
		    "select * from movie where lower(primary_title) regexp ?"
		    film)
		 (imdb-select-where
		    "select * from movie where lower(primary_title) like ?"
		    (format "%%%s%%" film))))
	(inhibit-read-only t))
    (erase-buffer)
    (imdb-kill)
    (setq films (imdb-mode-filter films))
    (unless films
      (error "No films match %S" film))
    (dolist (film (cl-sort films '<
			   :key (lambda (e)
				  (or (getf e :start-year)
				      most-positive-fixnum))))
      (insert
       (propertize
	(format "%s %s%s%s%s\n"
		(imdb-face (getf film :start-year))
		(propertize " " 'display '(space :align-to 8))
		(imdb-face (getf film :primary-title))
		(if (equal (getf film :type) "movie")
		    ""
		  (imdb-face (format " (%s)"
				     (imdb-display-type (getf film :type)))
			     "#80a080"))
		(let ((directors
		       (imdb-select-where "select primary_name from person inner join crew on crew.pid = person.pid where crew.category = 'director' and crew.mid = ?"
					  (getf film :mid))))
		  (if (not directors)
		      ""
		    (imdb-face
		     (concat " " (mapconcat (lambda (e)
					      (getf e :primary-name))
					    directors ", "))
		     "#80a080"))))
	'id (getf film :mid))))
    (goto-char (point-min))))

(defun imdb-query-user (prompt)
  (let ((default (thing-at-point 'word)))
    (when default
      (setq default (substring-no-properties default))
      (when imdb-mode-regexp-p
	(setq default (regexp-quote default))))
    (downcase
     (read-string
      (format "%s (%s%s): "
	      prompt
	      (if imdb-mode-regexp-p
		  "regexp"
		"substring")
	      (if default
		  (format ", default %s" default)
		""))
      nil nil default))))

(defun imdb-person (person)
  "List films matching PERSON."
  (interactive (list (imdb-query-user "Person")))
  (imdb-initialize)
  (switch-to-buffer (format "*imdb %s*" person))
  (let ((inhibit-read-only t))
    (imdb-mode)
    (setq imdb-mode-mode 'people-search
	  imdb-mode-search person)
    (erase-buffer)
    (imdb-mode-search-person-1 person)))

(defun imdb-mode-search-person-1 (person)
  (let ((people (if imdb-mode-regexp-p
		    (imdb-select-where
		     "select * from person where lower(primary_name) regexp ?"
		     person)
		  (imdb-select-where
		   "select * from person where lower(primary_name) like ?"
		   (format "%%%s%%" person))))
	(inhibit-read-only t))
    (erase-buffer)
    (imdb-kill)
    (unless people
      (error "No people match %S" person))
    (dolist (person (cl-sort people 'string<
			     :key (lambda (e)
				    (getf e :primary-anem))))
      (insert
       (propertize
	(format
	 "%s%s%s\n"
	 (imdb-face (getf person :primary-name))
	 (if (not (getf person :birth-year))
	     ""
	   (imdb-face (format " (%s)" (getf person :birth-year)) "#a0a0a0"))
	 (let ((known (imdb-select 'person-known-for :pid (getf person :pid))))
	   (if (not known)
	       ""
	     (imdb-face
	      (format " (%s)"
		      (mapconcat
		       (lambda (e)
			 (getf (car (imdb-select 'movie :mid (getf e :mid)))
			       :primary-title))
		       known
		       ", "))
	      "#a0a0a0"))))
	'id (getf person :pid))))
    (goto-char (point-min))))

(defun imdb-mode-filter (films)
  (let ((films
	 (if (not imdb-mode-filter-insignificant)
	     films
	   (loop for film in films
		 when (and (getf film :start-year)
			   (equal (getf film :type) "movie")
			   (not (member (getf film :category)
					'("thanks" "miscellaneous"
					  "camera_department"
					  "self" "archive_footage"
					  "sound_department"))))
		 collect film))))
    (if (not imdb-mode-filter-job)
	films
      (loop for film in films
	    when (or (and (eq imdb-mode-filter-job 'acting)
			  (member (getf film :category)
				  '("actor" "actress")))
		     (and (eq imdb-mode-filter-job 'directing)
			  (member (getf film :category)
				  '("director"))))
	    collect film))))

(defun imdb-mode-select ()
  "Select the item under point and display details."
  (interactive)
  (let ((id (get-text-property (point) 'id)))
    (unless id
      (error "Nothing under point"))
    (cond
     ((or (eq imdb-mode-mode 'film-search)
	  (eq imdb-mode-mode 'intersection)
	  (eq imdb-mode-mode 'person))
      (imdb-mode-display-film id))
     (t
      (switch-to-buffer (format "*imdb %s*"
				(getf (car (imdb-select 'person :pid id))
				      :primary-name)))
      (let ((inhibit-read-only t))
	(imdb-mode)
	(imdb-mode-display-person id))))))

(defun imdb-mode-open-imdb ()
  "Open the item under point in a web browser."
  (interactive)
  (browse-url-default-browser (imdb-mode-get-url)))

(defun imdb-mode-load-all-images ()
  "Expand all the actor images in the current buffer."
  (interactive)
  (unless (eq imdb-mode-mode 'film)
    (error "This command only works when displaying films"))
  (let ((pids nil)
	match)
  (save-excursion
    (goto-char (point-min))
    (while (setq match (text-property-search-forward 'placeholder t t))
      (push (get-text-property (prop-match-beginning match) 'id) pids)))
  (if (not pids)
      (message "Nothing to expand")
    (message "Expanding...")
    (imdb-load-people-images (nreverse pids) (current-buffer) 100 150 3))))

(defun imdb-mode-copy-url ()
  "Copy the item URL under point to the kill ring."
  (interactive)
  (let ((url (imdb-mode-get-url)))
    (with-temp-buffer
      (insert url)
      (copy-region-as-kill (point-min) (point-max))
      (message "Copied %S" (buffer-string)))))

(defun imdb-mode-get-url ()
  "Find the logical url for the current buffer/point."
  (let ((id (get-text-property (point) 'id)))
    (if (not id)
	(cond
	 ((eq imdb-mode-mode 'person)
	  (imdb-mode-person-url imdb-mode-search))
	 ((eq imdb-mode-mode 'film)
	  (imdb-mode-film-url imdb-mode-search))
	 (t
	  (error "Nothing under point")))
      (cond
       ((or (eq imdb-mode-mode 'film-search)
	    (eq imdb-mode-mode 'person))
	(imdb-mode-film-url id))
       ((or (eq imdb-mode-mode 'people-search)
	    (eq imdb-mode-mode 'film))
	(imdb-mode-person-url id))))))

(defun imdb-mode-person-url (id)
  (format "https://www.imdb.com/name/%s/" id))

(defun imdb-mode-film-url (id)
  (format "https://www.imdb.com/title/%s/" id))

(defun imdb-mode-display-film (id)
  (switch-to-buffer (format "*imdb %s*"
			    (getf (car (imdb-select 'movie :mid id))
				  :primary-title)))
  (let ((inhibit-read-only t)
	(film (car (imdb-select 'movie :mid id))))
    (erase-buffer)
    (imdb-kill)
    (imdb-mode)
    (setq imdb-mode-mode 'film
	  imdb-mode-search id)
    (imdb-insert-placeholder 300 400)
    (insert "\n\n")
    (imdb-update-film-image id)
    (let ((directors
	   (imdb-select-where "select primary_name from person inner join crew on crew.pid = person.pid where crew.category = 'director' and crew.mid = ?"
			      id)))
      (insert
       (if (not directors)
	   ""
	 (concat
	  (imdb-face "Directed by ")
	  (imdb-face (mapconcat (lambda (e)
				   (getf e :primary-name))
				 directors ", ")
		     '(:foreground "#f0f0f0"
				   :weight bold))))
       "\n"))

    (let ((rating (car (imdb-select 'rating :mid id))))
      (when rating
	(insert
	 (imdb-face (format "Rating %s / %s votes"
			     (getf rating :rating)
			     (getf rating :votes))
		    "#b0b0b0")))
      (when (getf film :length)
	(when rating
	  (insert (imdb-face " / " "#b0b0b0")))
	(insert 
	 (imdb-face (format "%d mins" (getf film :length)) "#b0b0b0"))))
    (insert "\n")

    (let ((genres (imdb-select 'movie-genre :mid id)))
      (when genres
	(insert 
	 (imdb-face
	  (mapconcat (lambda (e) (getf e :genre)) genres ", ")
	  "#b0b0b0")))
      (when (getf film :type)
	(when genres
	  (insert (imdb-face " ")))
	(insert 
	 (imdb-face (format "(%s)" (imdb-display-type (getf film :type)))
		    "#b0b0b0")))
      (when (or (getf film :type)
		genres)
	(insert "\n")))

    (insert "\n")
    
    (dolist (person (cl-sort
		     (imdb-select 'principal :mid id) '<
		     :key (lambda (e)
			    (let ((job (getf e :category)))
			      (cond
			       ((equal job "director") 1)
			       ((equal job "actor") 2)
			       ((equal job "actress") 2)
			       ((equal job "writer") 4)
			       (t 5))))))
      (insert (propertize
	       (format
		"%s%s%s\n"
		(imdb-face
		 (getf (car (imdb-select 'person :pid (getf person :pid)))
		       :primary-name))
		(imdb-face
		 (format " (%s)" (imdb-display-type (getf person :category)))
		 "#c0c0c0")
		(let ((characters (imdb-select 'principal-character
					       :mid id
					       :pid (getf person :pid))))
		  (if (not characters)
		      ""
		    (imdb-face
		     (concat
		      " "
		      (mapconcat
		       (lambda (e)
			 (format "\"%s\"" (getf e :character)))
		       characters ", "))
		     "#a0a0f0"))))
	       'id (getf person :pid))))
    (goto-char (point-min))
    (forward-line 1)
    (imdb-get-actors id (current-buffer))))

(defun imdb-mode-display-person (id)
  (let ((inhibit-read-only t)
	(films (imdb-select-where
		"select movie.mid, primary_title, start_year, type, principal.category from movie inner join principal on movie.mid = principal.mid where pid = ?"
		id)))
    (erase-buffer)
    (imdb-kill)
    (imdb-insert-placeholder 300 400)
    (put-text-property (point-min) (point) 'id id)
    (insert "\n\n")
    (let ((person (car (imdb-select 'person :pid id))))
      (insert
       (imdb-face (getf person :primary-name) "#f0f0f0"))
      (when (getf person :birth-year)
	(insert
	 (imdb-face (format " (%s)" (getf person :birth-year)) "#a0a0a0"))))
    (insert "\n\n")
    (imdb-load-people-images (list id) (current-buffer) 300 400 0)
    (setq imdb-mode-mode 'person
	  imdb-mode-search id)
    ;; Add the extra films from the web.
    (dolist (film imdb-mode-extra-data)
      (unless (cl-member film films
			 :test (lambda (e1 e2)
				 (equal (getf e1 :mid) (getf e2 :mid))))
	(push film films)))
    (setq films (cl-sort
		 (reverse films) '<
		 :key (lambda (e)
			(or (getf e :start-year) 1.0e+INF))))
    (setq films (imdb-mode-filter films))
    (dolist (film films)
      (imdb-mode-person-film film id))
    (goto-char (point-min))
    (forward-line 2)
    (imdb-person-update-films id)))

(defun imdb-mode-person-film (film pid)
  (unless (equal (getf film :type) "tvEpisode") 
    (insert
     (propertize
      (format "%s %s%s%s%s%s%s\n"
	      (imdb-face (or (getf film :start-year) ""))
	      (propertize " " 'display '(space :align-to 8))
	      (imdb-face (getf film :primary-title))
	      (cond
	       ((equal (getf film :type) "movie")
		"")
	       ((equal (getf film :type) "tvSeries")
		(let ((count
		       (car
			(imdb-select-where
			 "select count(*) from movie inner join episode on movie.mid = episode.mid inner join principal_character on principal_character.mid = movie.mid where episode.movie = ? and principal_character.pid = ?"
			 (getf film :mid)
			 pid))))
		  (if (plusp (getf count :count))
		      (format " (tv series, %s episode%s)"
			      (getf count :count)
			      (if (> (getf count :count) 1)
				  "s"
				""))
		    (format " (tv series)"))))
	       (t
		(imdb-face (format " (%s)" (imdb-display-type
					    (getf film :type)))
			   "#a0a0a0")))
	      (imdb-face (format " (%s)" (imdb-display-type
					  (getf film :category)))
			 "#c0c0c0")
	      (let ((characters (imdb-select 'principal-character
					     :mid (getf film :mid)
					     :pid pid)))
		(if (not characters)
		    ""
		  (imdb-face
		   (concat
		    " "
		    (mapconcat
		     (lambda (e)
		       (format "%S" (getf e :character)))
		     characters ", "))
		   "#a0a0f0")))
	      (let ((directors
		     (imdb-select-where "select primary_name from person inner join crew on crew.pid = person.pid where crew.category = 'director' and crew.mid = ?"
					(getf film :mid))))
		(if (not directors)
		    ""
		  (imdb-face
		   (concat " " (mapconcat (lambda (e)
					    (getf e :primary-name))
					  directors ", "))
		   "#80a080"))))
      'id (getf film :mid)))))

(defun imdb-update-film-image (id)
  (let ((buffer (current-buffer)))
    (imdb-url-retrieve
     (imdb-mode-film-url id)
     (lambda (status)
       (goto-char (point-min))
       (if (or (not (search-forward "\n\n" nil t))
	       (getf status :error))
	   (imdb-placehold-film buffer)
	 (url-store-in-cache)
	 (imdb-update-film-image-1
	  (loop with dom = (libxml-parse-html-region (point) (point-max))
		for image in (dom-by-tag dom 'img)
		for src = (dom-attr image 'src)
		when (and src (string-match "_AL_" src))
		return (shr-expand-url
			(dom-attr (dom-parent dom image) 'href)
			"http://www.imdb.com/"))
	  buffer))
       (kill-buffer (current-buffer))))))

(defun imdb-placehold-film (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
	(save-excursion
	  (goto-char (point-min))
	  (delete-region (point) (1+ (point)))
	  (imdb-insert-placeholder 300 400 "black"))))))

(defun imdb-update-film-image-1 (url buffer)
  (if (not url)
      (imdb-placehold-film buffer)
    (imdb-url-retrieve
     url
     (lambda (_)
       (url-store-in-cache)
       (goto-char (point-min))
       (imdb-update-film-image-2 (imdb-extract-image-json) buffer)
       (kill-buffer (current-buffer))))))

(defun imdb-update-film-image-2 (json buffer)
  (let ((src (imdb-get-image-from-json json)))
    (if (not src)
	(imdb-placehold-film buffer)
      (imdb-url-retrieve
       src
       (lambda (status)
	 (goto-char (point-min))
	 (when (and (search-forward "\n\n" nil t)
		    (not (getf status :error)))
	   (url-store-in-cache)
	   (let ((data (buffer-substring (point) (point-max))))
	     (when (buffer-live-p buffer)
	       (with-current-buffer buffer
		 (save-excursion
		   (goto-char (point-min))
		   (let ((inhibit-read-only t))
		     (delete-region (point) (line-end-position))
		     (insert-image
		      (create-image data 'imagemagick t :height 400))))))))
	 (kill-buffer (current-buffer)))))))

(defun imdb-insert-placeholder (width height &optional color)
  (let* ((scale (image-compute-scaling-factor image-scaling-factor))
	 (svg (svg-create (* width scale) (* height scale))))
    (svg-gradient svg "background" 'linear '((0 . "#b0b0b0") (100 . "#808080")))
    (if color
	(svg-rectangle svg 0 0 (* width scale) (* height scale)
		       :fill-color color)
      (svg-rectangle svg 0 0 (* width scale) (* height scale)
		     :gradient "background"
                     :stroke-width 2
		     :stroke-color "black"))
    (insert-image (svg-image svg))))

(defun imdb-clean (string)
  (string-trim (replace-regexp-in-string "[  \t\n]+" " " string)))

(defun imdb-get-actors (mid buffer)
  (imdb-url-retrieve
   (format "https://www.imdb.com/title/%s/fullcredits?ref_=tt_cl_sm" mid)
   (lambda (status)
     (goto-char (point-min))
     (when (and (search-forward "\n\n" nil t)
		(not (getf status :error)))
       (url-store-in-cache)
       (let* ((table (dom-by-class
		      (libxml-parse-html-region (point) (point-max))
		      "cast_list"))
	      (people
	       (loop for line in (dom-by-tag table 'tr)
		     for link = (dom-by-tag line 'a)
		     for person = (dom-attr link 'href)
		     when (and person
			       (string-match "name/\\([^/]+\\)" person))
		     collect (list :pid (match-string 1 person)
				   :name (imdb-clean
					  (dom-texts
					   (cadr (dom-non-text-children line))))
				   :character (imdb-clean
					       (dom-texts
						(dom-by-class
						 line "character"))))))
	      updates)
	 (with-current-buffer buffer
	   (save-excursion
	     (goto-char (point-max))
	     (let ((inhibit-read-only t))
	       (insert "\n")
	       (dolist (person people)
		 (let ((start (point)))
		   (if (> (length updates) 10)
		       (let ((start (point)))
			 (imdb-insert-placeholder 100 150 "#004000")
			 (put-text-property start (point) 'placeholder t))
		     (push person updates)
		     (imdb-insert-placeholder 100 150))
		   (insert
		    (format " %s%s\n"
			    (imdb-face (getf person :name))
			    (if (equal (getf person :character) "")
				""
			      (imdb-face (format " \"%s\""
						 (getf person :character))
					 "#a0a0a0"))))
		   (put-text-property start (point)
				      'id (getf person :pid)))))))
	 (kill-buffer (current-buffer))
	 (when people
	   (imdb-load-people-images
	    (mapcar (lambda (e) (getf e :pid)) (nreverse updates))
	    buffer 100 150 3)))))))

(defun imdb-load-people-images (pids buffer width height newlines)
  (let ((pid (pop pids)))
    (imdb-url-retrieve
     (imdb-mode-person-url pid)
     (lambda (status)
       (goto-char (point-min))
       (when (and (search-forward "\n\n" nil t)
		  (not (getf status :error)))
	 (url-store-in-cache)
	 (let* ((dom (libxml-parse-html-region (point) (point-max)))
		(img (dom-attr (dom-by-tag (dom-by-id dom "img_primary")
					   'img)
			       'src)))
	   (if img
	       (imdb-url-retrieve
		img 
		(lambda (status)
		  (imdb-load-people-image status pid buffer height newlines)))
	     (when (buffer-live-p buffer)
	       (with-current-buffer buffer
		 (let ((inhibit-read-only t)
		       match)
		   (save-excursion
		     (goto-char (point-min))
		     (search-forward "\n\n" nil t newlines)
		     (when (setq match (text-property-search-forward
					'id pid t))
		       (goto-char (prop-match-beginning match))
		       (let ((id (get-text-property (point) 'id))
			     (start (point)))
			 (delete-region (point) (1+ (point)))
			 (imdb-insert-placeholder width height "black")
			 (put-text-property start (point) 'id id))))))))
	   (when pids
	     (imdb-load-people-images pids buffer width height newlines))))
       (kill-buffer (current-buffer))))))

(defun imdb-load-people-image (status pid buffer height newlines)
  (goto-char (point-min))
  (when (and (search-forward "\n\n" nil t)
	     (not (getf status :error)))
    (url-store-in-cache)
    (let ((data (buffer-substring (point) (point-max)))
	  match)
      (when (buffer-live-p buffer)
	(with-current-buffer buffer
	  (let ((inhibit-read-only t))
	    (save-excursion
	      (goto-char (point-min))
	      (search-forward "\n\n" nil t newlines)
	      (when (setq match (text-property-search-forward 'id pid t))
		(goto-char (prop-match-beginning match))
		(let ((id (get-text-property (point) 'id))
		      (start (point)))
		  (delete-region (point) (1+ (point)))
		  (insert-image
		   (create-image data 'imagemagick t :height height))
		  (put-text-property start (point) 'id id)))))))))
  (kill-buffer (current-buffer)))

(defun imdb-person-query-films (pid)
  "Query imdb.com for all films that PID has appeared in."
  (let ((did nil))
    (imdb-person-get-films
     pid
     (lambda (films)
       (setq did (or films t))))
    (while (not did)
      (sleep-for 0.1))
    (and (listp did)
	 did)))

(defun imdb-person-update-films (pid)
  (let ((buffer (current-buffer)))
    (imdb-person-get-films
     pid
     (lambda (films)
       (with-current-buffer buffer
	 (setq films (imdb-mode-filter films))
	 (setq imdb-mode-extra-data films)
	 (let ((inhibit-read-only t))
	   (save-excursion
	     (dolist (film films)
	       (goto-char (point-min))
	       (forward-line 4)
	       (unless (text-property-search-forward 'id (getf film :mid) t)
		 (if (not (getf film :start-year))
		     (goto-char (point-max))
		   (while (and (looking-at "[0-9]+")
			       (let ((year (string-to-number
					    (match-string 0))))
				 (<= year (getf film :start-year))))
		     (forward-line 1)))
		 (imdb-mode-person-film film pid))))))))))

(defun imdb-person-get-films (pid callback)
  (imdb-url-retrieve
   (imdb-mode-person-url pid)
   (lambda (_)
     (goto-char (point-min))
     (let (films)
       (when (search-forward "\n\n" nil t)
	 (url-store-in-cache)
	 (setq films
	       (loop for elem in (dom-by-class
				  (libxml-parse-html-region (point) (point-max))
				  "\\`filmo-row")
		     for link = (dom-by-tag elem 'a)
		     for href = (dom-attr link 'href)
		     for character = (car (last (dom-children elem)))
		     for year = (dom-by-class elem "\\`year")
		     when (and href year 
			       (string-match "/title/\\([^/]+\\)" href))
		     collect
		     ;; If we have the data on the film, use it.
		     (let ((film (car (imdb-select
				       'movie :mid (match-string 1 href)))))
		       (if film
			   (progn
			     (setf (getf film :category)
				   (car (split-string (dom-attr elem 'id) "-")))
			     film)
			 (list :mid (match-string 1 href)
			       :primary-title (imdb-clean (dom-texts link))
			       :type "movie"
			       :start-year
			       (string-to-number
				(car (split-string
				      (imdb-clean (dom-texts year)) "/")))
			       :category
			       (car (split-string (dom-attr elem 'id) "-"))
			       :character (and (stringp character)
					       (imdb-clean character)))))))
	 (setq films (cl-sort (nreverse films) '<
			      :key (lambda (elem)
				     (or (getf elem :year) 1.0e+INF)))))
       (funcall callback films)
       (kill-buffer (current-buffer))))))

(defun imdb-display-type (type)
  (pcase type
    ("tvSeries" "tv series")
    ("tvMovie" "tv movie")
    ("tvShort" "tv short")
    ("tvSpecial" "tv special")
    ("tvMiniSeries" "tv mini series")
    ("archive_footage" "footage")
    ("visual_effects" "effects")
    ("special_effects" "effects")
    ("camera_department" "camera dept")
    ("sound_department" "sound")
    ("actress" "actor")
    (_ (replace-regexp-in-string "_" " " type))))

(defvar imdb-buffers nil)

(defun imdb-url-retrieve (url callback)
  (let ((cache (url-cache-create-filename url)))
    (if (file-exists-p cache)
	(with-current-buffer (generate-new-buffer " *imdb url cache*")
	  (erase-buffer)
	  (set-buffer-multibyte nil)
	  (insert-file-contents-literally cache)
	  (funcall callback nil))
      (let ((buffer (url-retrieve url callback nil t t)))
	(push buffer imdb-buffers)))))

(defun imdb-kill ()
  (dolist (buffer imdb-buffers)
    (when (buffer-live-p buffer)
      (when (get-buffer-process buffer)
	(delete-process (get-buffer-process buffer)))
      (when (buffer-live-p buffer)
	(with-current-buffer buffer
	  (let ((kill-buffer-query-functions nil))
	    (kill-buffer buffer))))))
  (setq imdb-buffers nil))

(provide 'imdb-mode)

;;; imdb-mode.el ends here
